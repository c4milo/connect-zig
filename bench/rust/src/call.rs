//! The routed calls: the counterpart of bench/call.zig and bench/go/call.go. One unary call of a
//! message through connect-rust's service, in memory. `ConnectRpcService` is a tower `Service`
//! over `http::Request`, so the call runs with no socket, no framing and no TLS, as on the Zig
//! side. connect-rust, the `connectrpc` crate, encodes with Buffa. A current-thread Tokio runtime
//! drives each call's future.
//!
//! The handler answers the message with itself. A map field is a BTreeMap, so each reply's
//! octets equal its request's, as Zig's do.

use std::path::Path;

use bytes::Bytes;
use connectrpc::{
    handler_fn, ConnectRpcService, JsonDeserialize, JsonSerialize, RequestContext, Response, Router,
};
use http_body_util::{BodyExt, Full};
use tower::Service;

use crate::measure::{self, Run, Settings};
use crate::{BYTES_PER_MEGABYTE, NANOSECONDS_PER_SECOND};

/// A protocol of the routed calls: the table's label, the request's content type, and the end of
/// the name of the reply's file.
struct CallProtocol {
    label: &'static str,
    content_type: &'static str,
    file_suffix: &'static str,
    grpc: bool,
}

const CALL_PROTOCOLS: [CallProtocol; 2] = [
    CallProtocol {
        label: "Connect unary call",
        content_type: "application/proto",
        file_suffix: "connect.reply",
        grpc: false,
    },
    CallProtocol {
        label: "gRPC unary call",
        content_type: "application/grpc+proto",
        file_suffix: "grpc.reply",
        grpc: true,
    },
];

/// gRPC's "Length-Prefixed-Message": a flag octet, then the length in four octets.
const PREFIX_LEN: usize = 5;

/// A routed call of one message in one protocol.
struct RoutedCall {
    protocol: &'static CallProtocol,
    procedure: String,
    service: ConnectRpcService<Router>,
    runtime: tokio::runtime::Runtime,
    body: Bytes,
}

/// What one call answered: its HTTP status, its gRPC status, and its body.
struct Reply {
    status: u16,
    grpc_status: Option<String>,
    body: Bytes,
}

impl RoutedCall {
    fn new(protocol: &'static CallProtocol, name: &str, router: Router, encoded: &[u8]) -> Self {
        let mut body = Vec::with_capacity(PREFIX_LEN + encoded.len());
        if protocol.grpc {
            body.push(0);
            body.extend_from_slice(&(encoded.len() as u32).to_be_bytes());
        }
        body.extend_from_slice(encoded);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .expect("a current-thread runtime");
        RoutedCall {
            protocol,
            procedure: format!("/bench.v1.Bench/Echo{name}"),
            service: ConnectRpcService::new(router),
            runtime,
            body: Bytes::from(body),
        }
    }

    /// Runs one call and returns what it answered.
    fn serve(&mut self) -> Result<Reply, String> {
        let mut builder = http::Request::builder()
            .method(http::Method::POST)
            .uri(self.procedure.as_str())
            .header(http::header::CONTENT_TYPE, self.protocol.content_type);
        if self.protocol.grpc {
            // gRPC runs over HTTP/2 (PROTOCOL-HTTP2.md), and asks for trailers.
            builder = builder
                .version(http::Version::HTTP_2)
                .header(http::header::TE, "trailers");
        }
        let request = builder
            .body(Full::new(self.body.clone()))
            .map_err(|error| error.to_string())?;
        let service = &mut self.service;
        self.runtime.block_on(async move {
            let Ok(response) = service.call(request).await;
            let status = response.status().as_u16();
            let collected = response
                .into_body()
                .collect()
                .await
                .map_err(|error| error.to_string())?;
            let grpc_status = collected
                .trailers()
                .and_then(|trailers| trailers.get("grpc-status"))
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            Ok(Reply {
                status,
                grpc_status,
                body: collected.to_bytes(),
            })
        })
    }

    /// Runs one call and checks that it answered 200 with its request's octets.
    fn reply(&mut self) -> Result<Bytes, String> {
        let label = self.protocol.label;
        let reply = self.serve()?;
        if reply.status != 200 {
            return Err(format!("{label}: HTTP {}", reply.status));
        }
        if self.protocol.grpc && reply.grpc_status.as_deref() != Some("0") {
            return Err(format!("{label}: grpc-status {:?}", reply.grpc_status));
        }
        if reply.body != self.body {
            return Err(format!("{label}: the reply differs from the request"));
        }
        Ok(reply.body)
    }

    fn runner(&mut self) -> Run<'_> {
        Box::new(move |n| {
            for _ in 0..n {
                std::hint::black_box(self.serve()?.body.len());
            }
            Ok(())
        })
    }
}

/// connect-rust's router with one unary method, `Echo<name>` of bench.v1.Bench, which answers a
/// message with itself.
fn echo_router<T>(name: &str) -> Router
where
    T: buffa::Message + JsonDeserialize + JsonSerialize + Send + 'static,
{
    Router::new().route(
        "bench.v1.Bench",
        &format!("Echo{name}"),
        handler_fn(|_context: RequestContext, request: T| async move { Response::ok(request) }),
    )
}

/// Times the routed calls of one message, each after its reply is checked, and writes each reply
/// into `directory` when it is set.
pub fn run_calls<T>(
    current: &Settings,
    directory: Option<&str>,
    name: &'static str,
    method: &str,
    input: &T,
) -> Result<(), String>
where
    T: buffa::Message + JsonDeserialize + JsonSerialize + Send + 'static,
{
    let encoded = input.encode_to_vec();
    for protocol in &CALL_PROTOCOLS {
        let label = protocol.label;
        let mut call = RoutedCall::new(protocol, method, echo_router::<T>(method), &encoded);
        let reply = call.reply().map_err(|error| format!("{name}: {error}"))?;
        if let Some(directory) = directory {
            let path = Path::new(directory).join(format!("{name}.{}", protocol.file_suffix));
            std::fs::write(path, &reply).map_err(|error| format!("{name}: {error}"))?;
        }
        let size = call.body.len();
        let mut runner = call.runner();
        let ns = measure::median_ns(current, &mut runner)
            .map_err(|error| format!("{name}, {label}: {error}"))?;
        let megabytes_per_second = size as f64 / ns * NANOSECONDS_PER_SECOND / BYTES_PER_MEGABYTE;
        println!("| {name} | {label} | {size} | {ns:.1} | {megabytes_per_second:.1} |");
    }
    Ok(())
}
