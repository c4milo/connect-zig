//! The connect-rust interop server: `connectrpc`'s standalone server, serving Connect, gRPC and
//! gRPC-Web over TLS with the test identity, h2 and HTTP/1.1 picked by ALPN. connect-zig's
//! interop client calls it (interop/README.md, "The server side"). It answers as connect-zig's
//! own server of examples/services/interop.zig does.

use std::sync::Arc;

use connectrpc::{
    ConnectError, ErrorCode, ErrorDetail, InboundStream, RequestContext, Response, Router,
    Server, ServiceRequest, ServiceResult, ServiceStream,
};
use futures::StreamExt as _;

use crate::proto::coverage::v1::Everything;
use crate::proto::interop::v1::{
    CollectResponse, FailRequest, InspectRequest, InspectResponse, InteropService, RepeatRequest,
};

/// The most messages Repeat sends, as examples/services/interop.zig allows.
const REPEAT_MAX: i32 = 16;
/// The prefix of the request headers Inspect reports and sends back.
const INSPECTED_PREFIX: &str = "x-interop-";
/// statuscodes.md: the codes a failure may carry are 1 to 16.
const CODE_MIN: i32 = 1;
const CODE_MAX: i32 = 16;
/// The full name the Fail detail carries.
const FAIL_DETAIL_TYPE: &str = "interop.v1.FailRequest";

struct Interop;

// The handlers name their concrete messages, which the trait's `impl Encodable` allows.
#[allow(refining_impl_trait)]
impl InteropService for Interop {
    async fn echo(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, Everything>,
    ) -> ServiceResult<Everything> {
        Response::ok(request.to_owned_message())
    }

    async fn echo_get(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, Everything>,
    ) -> ServiceResult<Everything> {
        Response::ok(request.to_owned_message())
    }

    async fn repeat(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, RepeatRequest>,
    ) -> ServiceResult<ServiceStream<Everything>> {
        let request = request.to_owned_message();
        if request.count < 0 || request.count > REPEAT_MAX {
            return Err(ConnectError::out_of_range("count must be between 0 and 16"));
        }
        let message = request.message.as_option().cloned().unwrap_or_default();
        let copies = vec![Ok(message); request.count as usize];
        Response::stream_ok(futures::stream::iter(copies))
    }

    async fn collect(
        &self,
        _ctx: RequestContext,
        mut requests: InboundStream<Everything>,
    ) -> ServiceResult<CollectResponse> {
        let mut response = CollectResponse::default();
        while let Some(request) = requests.next().await {
            response.count += 1;
            response.last = request?.to_owned_message().into();
        }
        Response::ok(response)
    }

    async fn chat(
        &self,
        _ctx: RequestContext,
        requests: InboundStream<Everything>,
    ) -> ServiceResult<ServiceStream<Everything>> {
        // Each answer goes as its message arrives, while the client still sends.
        Response::stream_ok(requests.map(|request| request.map(|each| each.to_owned_message())))
    }

    async fn fail(
        &self,
        _ctx: RequestContext,
        request: ServiceRequest<'_, FailRequest>,
    ) -> ServiceResult<Everything> {
        let request = request.to_owned_message();
        if request.code < CODE_MIN || request.code > CODE_MAX {
            return Err(ConnectError::invalid_argument("code must be between 1 and 16"));
        }
        let code = ErrorCode::from_grpc_code(request.code as u32)
            .ok_or_else(|| ConnectError::internal("no such code"))?;
        let detail = ErrorDetail::from_message(FAIL_DETAIL_TYPE, &request);
        Err(ConnectError::new(code, request.message.clone()).with_detail(detail))
    }

    async fn inspect(
        &self,
        ctx: RequestContext,
        _request: ServiceRequest<'_, InspectRequest>,
    ) -> ServiceResult<InspectResponse> {
        let mut response = InspectResponse::default();
        if let Some(remaining) = ctx.time_remaining() {
            response.timeout_ms = remaining.as_millis() as i64;
        }
        let seen: Vec<_> = ctx
            .headers()
            .iter()
            .filter(|(name, _)| name.as_str().starts_with(INSPECTED_PREFIX))
            .map(|(name, value)| (name.clone(), value.clone()))
            .collect();
        for (name, value) in &seen {
            let value = value.to_str().unwrap_or_default();
            response.headers.push(format!("{}: {value}", name.as_str()));
        }
        let mut answer = Response::new(response);
        for (name, value) in seen {
            answer = answer
                .with_header(name.clone(), value.clone())
                .with_trailer(name, value);
        }
        Ok(answer)
    }
}

/// The test identity: the chain the server presents and its key.
fn identity(chain: &str, key: &str) -> Result<Arc<rustls::ServerConfig>, Box<dyn std::error::Error>> {
    let chain_pem = std::fs::read(chain)?;
    let certificates = rustls_pemfile::certs(&mut chain_pem.as_slice()).collect::<Result<Vec<_>, _>>()?;
    let key_pem = std::fs::read(key)?;
    let key = rustls_pemfile::private_key(&mut key_pem.as_slice())?.ok_or("no private key")?;
    let mut config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certificates, key)?;
    // RFC 7301 §3: the server picks h2 or HTTP/1.1 from the client's offer.
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

/// Serves on 127.0.0.1 at `port`, 0 letting the kernel choose, and prints the port.
pub async fn serve(port: &str, chain: &str, key: &str) -> Result<(), Box<dyn std::error::Error>> {
    let tls = identity(chain, key)?;
    let router = Router::new().add_service(Arc::new(Interop));
    let bound = Server::bind(format!("127.0.0.1:{port}"))
        .await
        .map_err(|error| error.to_string())?
        .with_tls(tls);
    println!("listening on port {}", bound.local_addr()?.port());
    bound.serve(router).await.map_err(|error| error.to_string())?;
    Ok(())
}
