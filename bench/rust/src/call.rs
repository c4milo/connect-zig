//! The routed calls: the counterpart of bench/call.zig and bench/go/call.go. One unary call of a
//! message through connect-rust's service, in memory. `ConnectRpcService` is a tower `Service`
//! over `http::Request`, so the call runs with no socket, no framing and no TLS, as on the Zig
//! side. connect-rust, the `connectrpc` crate, encodes with Buffa. A current-thread Tokio runtime
//! drives each call's future.
//!
//! The Zig side replays a request head it built once. The service takes each request by value,
//! so each call here clones the head the builder made once, and gives it the body.
//!
//! The handler answers the message with itself. A map field is a BTreeMap, so each reply's
//! octets equal its request's, as Zig's do.
//!
//! The router holds 1, 16 or 256 routes, as bench/call.zig's tables do: the echo method's, then
//! more methods of its service, then more services of as many methods. The calls never reach the
//! other routes.

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

/// The sizes of the route tables the small message's calls run on, as bench/constants.zig's
/// call_route_counts: each a square of services and methods.
pub const CALL_ROUTE_COUNTS: [usize; 3] = [1, 16, 256];

/// A routed call of one message in one protocol.
struct RoutedCall {
    protocol: &'static CallProtocol,
    service: ConnectRpcService<Router>,
    runtime: tokio::runtime::Runtime,
    body: Bytes,
    head: http::request::Parts,
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
        let procedure = format!("/bench.v1.Bench/Echo{name}");
        let mut builder = http::Request::builder()
            .method(http::Method::POST)
            .uri(procedure.as_str())
            .header(http::header::CONTENT_TYPE, protocol.content_type);
        if protocol.grpc {
            // gRPC runs over HTTP/2 (PROTOCOL-HTTP2.md), and asks for trailers.
            builder = builder
                .version(http::Version::HTTP_2)
                .header(http::header::TE, "trailers");
        }
        let (head, ()) = builder
            .body(())
            .expect("a request of fixed parts")
            .into_parts();
        RoutedCall {
            protocol,
            service: ConnectRpcService::new(router),
            runtime,
            body: Bytes::from(body),
            head,
        }
    }

    /// Runs one call and returns what it answered.
    fn serve(&mut self) -> Result<Reply, String> {
        let request = http::Request::from_parts(self.head.clone(), Full::new(self.body.clone()));
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

/// connect-rust's router of `routes` unary methods: `Echo<name>` of bench.v1.Bench, which answers
/// a message with itself, then the paths of bench/call.zig's filler_path: `Filler<j>` of its
/// service, then `Call<j>` of the services `bench.v1.Filler<i>`.
fn echo_router<T>(name: &str, routes: usize) -> Router
where
    T: buffa::Message + JsonDeserialize + JsonSerialize + Send + 'static,
{
    let side = (routes as f64).sqrt() as usize;
    assert_eq!(
        side * side,
        routes,
        "a route table is a square of services and methods"
    );
    let mut router = Router::new().route(
        "bench.v1.Bench",
        &format!("Echo{name}"),
        handler_fn(|_context: RequestContext, request: T| async move { Response::ok(request) }),
    );
    for index in 1..routes {
        let (service, method) = if index < side {
            ("bench.v1.Bench".to_owned(), format!("Filler{index:02}"))
        } else {
            (
                format!("bench.v1.Filler{:02}", index / side),
                format!("Call{:02}", index % side),
            )
        };
        router = router.route(
            &service,
            &method,
            handler_fn(|_context: RequestContext, request: T| async move { Response::ok(request) }),
        );
    }
    router
}

/// Times the routed calls of one message in a table of `routes` routes, each after its reply is
/// checked, and writes each reply into `directory` when it is set, from the table of one route. A
/// call in a larger table names the count after its own name, as "Connect unary call, 16 routes".
pub fn run_calls<T>(
    current: &Settings,
    directory: Option<&str>,
    name: &'static str,
    method: &str,
    input: &T,
    routes: usize,
) -> Result<(), String>
where
    T: buffa::Message + JsonDeserialize + JsonSerialize + Send + 'static,
{
    let encoded = input.encode_to_vec();
    for protocol in &CALL_PROTOCOLS {
        let label = if routes > 1 {
            format!("{}, {routes} routes", protocol.label)
        } else {
            protocol.label.to_owned()
        };
        let mut call =
            RoutedCall::new(protocol, method, echo_router::<T>(method, routes), &encoded);
        let reply = call.reply().map_err(|error| format!("{name}: {error}"))?;
        if let (Some(directory), 1) = (directory, routes) {
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
