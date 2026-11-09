//! The connect-rust interop client: it runs each scenario of interop/README.md through the
//! `connectrpc` crate, in Connect with proto and JSON, Connect over HTTP/1.1, gRPC and gRPC-Web,
//! over TLS that trusts the given CA, and prints one `ok:` or `FAIL:` line for each.

use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use buffa::Message;
use connectrpc::client::{
    call_unary_get, CallOptions, ClientConfig, ClientTransport, HttpClient, ServiceTransport,
};
use connectrpc::compression::CompressionPolicy;
use connectrpc::{ConnectError, ErrorCode, Protocol, SpecOrigin};
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client as LegacyClient;
use hyper_util::rt::TokioExecutor;

#[allow(dead_code, clippy::all)]
mod proto {
    connectrpc::include_generated!();
}

use proto::coverage::v1::{Everything, EverythingView};
use proto::interop::v1::{
    FailRequest, InspectRequest, InteropServiceClient, RepeatRequest, INTEROP_SERVICE_ECHO_GET_SPEC,
};

type Outcome = Result<(), String>;

/// A transport whose response bodies the client's streams can read.
trait Transport:
    ClientTransport<ResponseBody: Unpin + connectrpc::http_body::Body<Error: std::fmt::Display>>
{
}

impl<T> Transport for T where
    T: ClientTransport<ResponseBody: Unpin + connectrpc::http_body::Body<Error: std::fmt::Display>>
{
}

/// The name the client prints and sends in `x-interop-client`.
const CLIENT: &str = "connect-rust";
/// The case that `repeat` sends.
const REPEAT_CASE: &str = "scalars";
/// How many copies `repeat` asks for.
const REPEAT_COUNT: i32 = 3;
/// How long a scenario may run before it fails.
const SCENARIO_LIMIT: Duration = Duration::from_secs(10);
/// The timeout `inspect` sends.
const INSPECT_TIMEOUT: Duration = Duration::from_secs(5);
/// The header `inspect` sends and expects back.
const CLIENT_HEADER: &str = "x-interop-client";
/// The type `fail` expects its one detail to hold.
const FAIL_DETAIL_TYPE: &str = "interop.v1.FailRequest";

#[derive(Clone)]
struct Case {
    name: String,
    message: Everything,
}

/// Each case as Buffa's JSON round trip gives it back. JSON's "NaN" holds no payload, so a NaN
/// whose bits differ from Rust's comes back as Rust's; the client expects that from a JSON echo.
fn through_json(cases: &[Case]) -> Vec<Case> {
    cases
        .iter()
        .map(|case| {
            let json = serde_json::to_vec(&case.message).expect("a case writes as JSON");
            let message = serde_json::from_slice(&json).expect("a case reads back from JSON");
            Case {
                name: case.name.clone(),
                message,
            }
        })
        .collect()
}

/// One protocol run: its name in the output, the client config, and what it can run.
struct Run<T> {
    protocol: &'static str,
    transport: T,
    config: ClientConfig,
    /// Chat needs full duplex, which HTTP/1.1 does not give.
    duplex: bool,
    /// GET is a Connect feature; gRPC and gRPC-Web are POST only.
    get: bool,
    /// Whether messages travel as JSON.
    json: bool,
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: interop-connect-rust <base-url> <cases-dir> <ca>");
        std::process::exit(2);
    }
    // An Any in JSON writes its payload as JSON, which needs every type it may hold registered.
    let mut registry = buffa::type_registry::TypeRegistry::new();
    buffa_types::register_wkt_types(&mut registry);
    proto::coverage::v1::register_types(&mut registry);
    proto::interop::v1::register_types(&mut registry);
    buffa::type_registry::set_type_registry(registry);
    let cases =
        read_cases(&args[2]).unwrap_or_else(|error| exit(&format!("reading cases: {error}")));
    let tls =
        trust(&args[3]).unwrap_or_else(|error| exit(&format!("reading {}: {error}", args[3])));
    let base: http::Uri = args[1]
        .parse()
        .unwrap_or_else(|_| exit("the base URL is not a URI"));
    // HttpClient offers h2 and http/1.1 by ALPN, and the server picks h2.
    let h2 = HttpClient::with_tls(tls.clone());
    // HttpClient offers h2 whatever the config says, so HTTP/1.1 goes through hyper's client with
    // http/1.1 alone in ALPN.
    let h1 = ServiceTransport::new(http1_client(tls));
    let config = || ClientConfig::new(base.clone());
    let mut failed = false;
    failed |= run_all(
        Run {
            protocol: "connect-proto",
            transport: h2.clone(),
            config: config(),
            duplex: true,
            get: true,
            json: false,
        },
        &cases,
    )
    .await;
    failed |= run_all(
        Run {
            protocol: "connect-json",
            transport: h2.clone(),
            config: config().json(),
            duplex: true,
            get: true,
            json: true,
        },
        &cases,
    )
    .await;
    failed |= run_all(
        Run {
            protocol: "connect-h1",
            transport: h1,
            config: config(),
            duplex: false,
            get: true,
            json: false,
        },
        &cases,
    )
    .await;
    let grpc = config().with_protocol(Protocol::Grpc);
    failed |= run_all(
        Run {
            protocol: "grpc",
            transport: h2.clone(),
            config: grpc,
            duplex: true,
            get: false,
            json: false,
        },
        &cases,
    )
    .await;
    let grpc_web = config().with_protocol(Protocol::GrpcWeb);
    failed |= run_all(
        Run {
            protocol: "grpc-web",
            transport: h2,
            config: grpc_web,
            duplex: true,
            get: false,
            json: false,
        },
        &cases,
    )
    .await;
    if failed {
        std::process::exit(1);
    }
}

fn exit(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(2);
}

/// A TLS config that trusts the CA in the PEM file, and no other.
fn trust(path: &str) -> Result<Arc<rustls::ClientConfig>, Box<dyn std::error::Error>> {
    let pem = std::fs::read(path)?;
    let mut roots = rustls::RootCertStore::empty();
    for certificate in rustls_pemfile::certs(&mut pem.as_slice()) {
        roots.add(certificate?)?;
    }
    if roots.is_empty() {
        return Err(format!("{path} holds no certificate").into());
    }
    Ok(Arc::new(
        rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth(),
    ))
}

type Http1Client =
    LegacyClient<hyper_rustls::HttpsConnector<HttpConnector>, connectrpc::client::ClientBody>;

fn http1_client(tls: Arc<rustls::ClientConfig>) -> Http1Client {
    let mut config = (*tls).clone();
    // hyper-rustls sets ALPN itself from the versions it enables.
    config.alpn_protocols.clear();
    let https = hyper_rustls::HttpsConnectorBuilder::new()
        .with_tls_config(config)
        .https_only()
        .enable_http1()
        .build();
    LegacyClient::builder(TokioExecutor::new()).build(https)
}

/// Reads every `<name>.binpb` file of the directory, sorted by name.
fn read_cases(dir: &str) -> Result<Vec<Case>, Box<dyn std::error::Error>> {
    let mut paths: Vec<_> = std::fs::read_dir(dir)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<_, _>>()?;
    paths.retain(|path| {
        path.extension()
            .is_some_and(|extension| extension == "binpb")
    });
    paths.sort();
    let mut cases = Vec::with_capacity(paths.len());
    for path in paths {
        let name = path
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let message = Everything::decode_from_slice(&std::fs::read(&path)?)?;
        cases.push(Case { name, message });
    }
    if cases.is_empty() {
        return Err(format!("no .binpb files in {dir}").into());
    }
    Ok(cases)
}

/// Runs every scenario the run can express and answers whether any failed.
async fn run_all<T>(run: Run<T>, cases: &[Case]) -> bool
where
    T: Transport,
{
    let expected = if run.json {
        through_json(cases)
    } else {
        cases.iter().map(Case::clone).collect()
    };
    let cases = expected.as_slice();
    let plain = InteropServiceClient::new(run.transport.clone(), run.config.clone());
    // Compress every request, however small, as connect-go's WithCompressMinBytes(0) does.
    let gzip_config = run
        .config
        .clone()
        .compress_requests("gzip")
        .with_compression_policy(CompressionPolicy::default().with_min_size(0));
    let gzip = InteropServiceClient::new(run.transport.clone(), gzip_config);
    let mut failed = false;
    for case in cases {
        failed |= report(
            run.protocol,
            &format!("echo {}", case.name),
            echo(&plain, &case.message),
        )
        .await;
        failed |= report(
            run.protocol,
            &format!("echo-gzip {}", case.name),
            echo(&gzip, &case.message),
        )
        .await;
        if run.get {
            let name = format!("echo-get {}", case.name);
            failed |= report(
                run.protocol,
                &name,
                echo_get(&run.transport, &run.config, &case.message),
            )
            .await;
        }
    }
    failed |= report(run.protocol, "repeat", repeat(&plain, cases)).await;
    failed |= report(run.protocol, "collect", collect(&plain, cases)).await;
    if run.duplex {
        failed |= report(run.protocol, "chat", chat(&plain, cases)).await;
    }
    failed |= report(run.protocol, "fail", fail(&plain)).await;
    failed |= report(run.protocol, "inspect", inspect(&plain)).await;
    failed
}

/// Prints the scenario's line and answers whether it failed.
async fn report(
    protocol: &str,
    name: &str,
    scenario: impl std::future::Future<Output = Outcome>,
) -> bool {
    let outcome = match tokio::time::timeout(SCENARIO_LIMIT, scenario).await {
        Ok(outcome) => outcome,
        Err(_) => Err(format!("no answer within {SCENARIO_LIMIT:?}")),
    };
    match outcome {
        Ok(()) => {
            println!("ok: {CLIENT} {protocol} {name}");
            false
        }
        Err(detail) => {
            println!("FAIL: {CLIENT} {protocol} {name}: {detail}");
            true
        }
    }
}

/// Fails unless both messages encode to the same octets, which also holds for NaN. Buffa writes
/// a google.protobuf.Struct's fields in a HashMap's order, which no option fixes, so where the
/// octets differ the two messages' proto3 JSON is compared as a JSON value, whose objects ignore
/// key order and which writes a NaN as "NaN".
fn same<M: Message + serde::Serialize>(what: &str, want: &M, got: &M) -> Outcome {
    let (wanted, gotten) = (want.encode_to_vec(), got.encode_to_vec());
    if wanted == gotten || as_json(want)? == as_json(got)? {
        Ok(())
    } else {
        Err(format!(
            "{what} differs: wanted {} octets, got {}",
            wanted.len(),
            gotten.len()
        ))
    }
}

fn as_json(message: &impl serde::Serialize) -> Result<serde_json::Value, String> {
    serde_json::to_value(message).map_err(|error| format!("writing JSON: {error}"))
}

fn status_text(error: ConnectError) -> String {
    format!("{:?}: {}", error.code, error.message.unwrap_or_default())
}

async fn echo<T>(client: &InteropServiceClient<T>, message: &Everything) -> Outcome
where
    T: Transport,
{
    let response = client.echo(message.clone()).await.map_err(status_text)?;
    same("the echo", message, &response.into_owned())
}

/// EchoGet as a Connect GET, which connectrpc sends only when asked.
async fn echo_get<T>(transport: &T, config: &ClientConfig, message: &Everything) -> Outcome
where
    T: Transport,
{
    let spec = INTEROP_SERVICE_ECHO_GET_SPEC.with_origin(SpecOrigin::Client);
    let response = call_unary_get::<_, _, EverythingView<'static>>(
        transport,
        config,
        spec,
        message.clone(),
        CallOptions::default(),
    )
    .await
    .map_err(status_text)?;
    same("the echo", message, &response.into_owned())
}

async fn repeat<T>(client: &InteropServiceClient<T>, cases: &[Case]) -> Outcome
where
    T: Transport,
{
    let case = cases
        .iter()
        .find(|case| case.name == REPEAT_CASE)
        .unwrap_or(&cases[0]);
    let request = RepeatRequest {
        message: case.message.clone().into(),
        count: REPEAT_COUNT,
        ..Default::default()
    };
    let mut stream = client.repeat(request).await.map_err(status_text)?;
    let mut received = 0;
    while let Some(message) = stream.message().await.map_err(status_text)? {
        same(
            &format!("copy {received}"),
            &case.message,
            &message.to_owned_message(),
        )?;
        received += 1;
    }
    if received != REPEAT_COUNT {
        return Err(format!("want {REPEAT_COUNT} copies, got {received}"));
    }
    Ok(())
}

async fn collect<T>(client: &InteropServiceClient<T>, cases: &[Case]) -> Outcome
where
    T: Transport,
{
    let messages: Vec<Everything> = cases.iter().map(|case| case.message.clone()).collect();
    let response = client
        .collect(connectrpc::stream_iter(messages))
        .await
        .map_err(status_text)?
        .into_owned();
    if response.count != cases.len() as i32 {
        return Err(format!(
            "want count {}, got {}",
            cases.len(),
            response.count
        ));
    }
    let last = &cases[cases.len() - 1].message;
    same(
        "the last message",
        last,
        &response.last.as_option().cloned().unwrap_or_default(),
    )
}

/// Sends each case only after the echo of the one before it arrived, which needs full duplex.
async fn chat<T>(client: &InteropServiceClient<T>, cases: &[Case]) -> Outcome
where
    T: Transport,
{
    let mut stream = client.chat().await.map_err(status_text)?;
    stream
        .send(cases[0].message.clone())
        .await
        .map_err(status_text)?;
    for (index, case) in cases.iter().enumerate() {
        let Some(message) = stream.message().await.map_err(status_text)? else {
            return Err(format!("the stream ended after {index} answers"));
        };
        same(
            &format!("answer to {}", case.name),
            &case.message,
            &message.to_owned_message(),
        )?;
        match cases.get(index + 1) {
            Some(next) => stream
                .send(next.message.clone())
                .await
                .map_err(status_text)?,
            None => stream.close_send(),
        }
    }
    if let Some(extra) = stream.message().await.map_err(status_text)? {
        return Err(format!("an extra answer: {:?}", extra.to_owned_message()));
    }
    Ok(())
}

async fn fail<T>(client: &InteropServiceClient<T>) -> Outcome
where
    T: Transport,
{
    let request = FailRequest {
        code: 5,
        message: "gone".into(),
        ..Default::default()
    };
    let error = match client.fail(request.clone()).await {
        Ok(response) => return Err(format!("want an error, got {:?}", response.into_owned())),
        Err(error) => error,
    };
    if error.code != ErrorCode::NotFound || error.message.as_deref() != Some("gone") {
        return Err(format!(
            "want NotFound \"gone\", got {}",
            status_text(error)
        ));
    }
    let [detail] = error.details.as_slice() else {
        return Err(format!("want one detail, got {}", error.details.len()));
    };
    // Connect names the bare type; gRPC's Any adds a type.googleapis.com/ prefix.
    if detail.type_url.rsplit('/').next() != Some(FAIL_DETAIL_TYPE) {
        return Err(format!(
            "want a {FAIL_DETAIL_TYPE} detail, got {}",
            detail.type_url
        ));
    }
    let encoded = detail.value.as_deref().unwrap_or_default();
    let octets = base64::engine::general_purpose::STANDARD_NO_PAD
        .decode(encoded.trim_end_matches('='))
        .map_err(|error| format!("the detail's base64: {error}"))?;
    let held = FailRequest::decode_from_slice(&octets).map_err(|error| error.to_string())?;
    same("the detail", &request, &held)
}

async fn inspect<T>(client: &InteropServiceClient<T>) -> Outcome
where
    T: Transport,
{
    let options = CallOptions::default()
        .with_timeout(INSPECT_TIMEOUT)
        .with_header(CLIENT_HEADER, CLIENT);
    let response = client
        .inspect_with_options(InspectRequest::default(), options)
        .await
        .map_err(status_text)?;
    let header = response
        .headers()
        .get(CLIENT_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let trailer = response
        .trailers()
        .get(CLIENT_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let answer = response.into_owned();
    let maximum_ms = INSPECT_TIMEOUT.as_millis() as i64;
    if answer.timeout_ms < 1 || answer.timeout_ms > maximum_ms {
        return Err(format!(
            "want a timeout in 1..={maximum_ms} ms, got {}",
            answer.timeout_ms
        ));
    }
    let seen = format!("{CLIENT_HEADER}: {CLIENT}");
    if !answer.headers.contains(&seen) {
        return Err(format!(
            "want header {seen:?} seen, got {:?}",
            answer.headers
        ));
    }
    if header.as_deref() != Some(CLIENT) {
        return Err(format!("want response header {seen:?}, got {header:?}"));
    }
    if trailer.as_deref() != Some(CLIENT) {
        return Err(format!("want trailer {seen:?}, got {trailer:?}"));
    }
    Ok(())
}
