//! The full-stack check's OTLP receiver on connect-rust (design §8 step 31, decision 46).
//! `connectrpc`'s standalone server serves OpenTelemetry's TraceService/Export over TLS with the
//! test identity, h2 and HTTP/1.1 picked by ALPN. Each export arrives decoded as Buffa's view,
//! which borrows the request's octets. The receiver counts its spans and drops it, as
//! tools/otlp_sink does. Its server has no plain route, so a second port, on cleartext
//! HTTP/1.0, answers `requests <n> spans <n>`, as the sink's `GET /sink/count` does.
//!
//!     fullstack-connect-rust <port> <count port> <chain> <key> [validate]
//!
//! With `validate`, it first checks each export's view against the rules of
//! tools/fullstack/validate's schema with protovalidate-buffa, as `otlp-sink-validate` does, and
//! refuses one that breaks a rule with `invalid_argument`.

use std::io::{Read as _, Write as _};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use connectrpc::{RequestContext, Response, Router, Server, ServiceRequest, ServiceResult};

#[allow(dead_code, clippy::all)]
mod proto {
    connectrpc::include_generated!();
}

#[allow(clippy::all, non_camel_case_types, dead_code, unused_imports)]
mod validators {
    include!(concat!(env!("OUT_DIR"), "/validators/mod.rs"));
}

use protovalidate_buffa::Validate as _;

use proto::opentelemetry::proto::collector::trace::v1::{
    ExportTraceServiceRequest, ExportTraceServiceResponse, TraceService,
};

/// The octets of a count request the receiver reads before it answers: its request line and
/// headers, which it does not parse.
const COUNT_REQUEST_LEN: usize = 1024;

/// The exports and the spans the receiver took.
#[derive(Default)]
struct Counts {
    requests: AtomicU64,
    spans: AtomicU64,
}

struct Receiver {
    counts: Arc<Counts>,
    /// Whether each export is validated before its spans are counted.
    validate: bool,
}

#[allow(refining_impl_trait)]
impl TraceService for Receiver {
    async fn export(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, ExportTraceServiceRequest>,
    ) -> ServiceResult<ExportTraceServiceResponse> {
        if self.validate {
            if let Err(error) = (*request).validate() {
                return Err(error.into_connect_error());
            }
        }
        let mut spans = 0u64;
        for resource in request.resource_spans.iter() {
            for scope in resource.scope_spans.iter() {
                spans += scope.spans.len() as u64;
            }
        }
        self.counts.requests.fetch_add(1, Ordering::Relaxed);
        self.counts.spans.fetch_add(spans, Ordering::Relaxed);
        Response::ok(ExportTraceServiceResponse::default())
    }
}

/// The test identity: the chain the server presents and its key.
fn identity(
    chain: &str,
    key: &str,
) -> Result<Arc<rustls::ServerConfig>, Box<dyn std::error::Error>> {
    let chain_pem = std::fs::read(chain)?;
    let certificates =
        rustls_pemfile::certs(&mut chain_pem.as_slice()).collect::<Result<Vec<_>, _>>()?;
    let key_pem = std::fs::read(key)?;
    let key = rustls_pemfile::private_key(&mut key_pem.as_slice())?.ok_or("no private key")?;
    let mut config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certificates, key)?;
    // RFC 7301 §3: the server picks h2 or HTTP/1.1 from the client's offer.
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

/// Answers each connection on the count port with the counts, on a thread of its own, which
/// waits in `accept` while the load runs.
fn serve_counts(port: &str, counts: Arc<Counts>) -> std::io::Result<()> {
    let listener = std::net::TcpListener::bind(format!("127.0.0.1:{port}"))?;
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut request = [0u8; COUNT_REQUEST_LEN];
            let _ = stream.read(&mut request);
            let body = format!(
                "requests {} spans {}\n",
                counts.requests.load(Ordering::Relaxed),
                counts.spans.load(Ordering::Relaxed)
            );
            let _ = write!(
                stream,
                "HTTP/1.0 200 OK\r\ncontent-type: text/plain\r\ncontent-length: {}\r\n\r\n{body}",
                body.len()
            );
        }
    });
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let validate = args.len() == 6 && args[5] == "validate";
    if args.len() != 5 && !validate {
        return Err("usage: fullstack-connect-rust <port> <count port> <chain> <key> [validate]".into());
    }
    let counts = Arc::new(Counts::default());
    serve_counts(&args[2], counts.clone())?;
    let tls = identity(&args[3], &args[4])?;
    let router = Router::new().add_service(Arc::new(Receiver { counts, validate }));
    let bound = Server::bind(format!("127.0.0.1:{}", args[1]))
        .await
        .map_err(|error| error.to_string())?
        .with_tls(tls);
    println!("listening on port {}", bound.local_addr()?.port());
    bound
        .serve(router)
        .await
        .map_err(|error| error.to_string())?;
    Ok(())
}
