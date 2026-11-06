//! The tonic interop client: it runs each scenario of interop/README.md in gRPC over h2
//! cleartext and prints one `ok:` or `FAIL:` line for each.

use std::time::Duration;

use prost::Message;
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::codec::CompressionEncoding;
use tonic::transport::{Certificate, Channel, ClientTlsConfig};
use tonic::{Code, Request};

#[allow(dead_code)]
mod protos {
    include!(concat!(env!("OUT_DIR"), "/protos.rs"));
}

use protos::coverage::v1::Everything;
use protos::interop::v1::interop_service_client::InteropServiceClient;
use protos::interop::v1::{FailRequest, InspectRequest, InspectResponse, RepeatRequest};

type Client = InteropServiceClient<Channel>;
type Outcome = Result<(), String>;

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
const CLIENT_NAME: &str = "rust";

/// google.rpc.Status, which a gRPC server writes in the grpc-status-details-bin trailer.
#[derive(Clone, PartialEq, Message)]
struct RpcStatus {
    #[prost(int32, tag = "1")]
    code: i32,
    #[prost(string, tag = "2")]
    message: String,
    #[prost(message, repeated, tag = "3")]
    details: Vec<prost_types::Any>,
}

struct Case {
    name: String,
    message: Everything,
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: interop-rust <base-url> <cases-dir> <ca>");
        std::process::exit(2);
    }
    let cases = read_cases(&args[2]).unwrap_or_else(|error| {
        eprintln!("reading cases: {error}");
        std::process::exit(2);
    });
    // The server's TLS identity is the test one, whose CA the channel trusts.
    let ca = std::fs::read(&args[3]).unwrap_or_else(|error| {
        eprintln!("reading {}: {error}", args[3]);
        std::process::exit(2);
    });
    let tls = ClientTlsConfig::new().ca_certificate(Certificate::from_pem(ca));
    let channel = Channel::from_shared(args[1].clone())
        .expect("a valid base URL")
        .tls_config(tls)
        .unwrap_or_else(|error| {
            eprintln!("configuring TLS: {error}");
            std::process::exit(2);
        })
        .connect()
        .await
        .unwrap_or_else(|error| {
            eprintln!("connecting to {}: {error}", args[1]);
            std::process::exit(2);
        });
    let client = InteropServiceClient::new(channel.clone());

    let mut failed = false;
    for case in &cases {
        let name = format!("echo {}", case.name);
        failed |= report(&name, echo(client.clone(), &case.message)).await;
    }
    let gzip = client
        .clone()
        .send_compressed(CompressionEncoding::Gzip)
        .accept_compressed(CompressionEncoding::Gzip);
    for case in &cases {
        let name = format!("echo-gzip {}", case.name);
        failed |= report(&name, echo(gzip.clone(), &case.message)).await;
    }
    failed |= report("repeat", repeat(client.clone(), &cases)).await;
    failed |= report("collect", collect(client.clone(), &cases)).await;
    failed |= report("chat", chat(client.clone(), &cases)).await;
    failed |= report("fail", fail(client.clone())).await;
    failed |= report("inspect", inspect(channel)).await;
    if failed {
        std::process::exit(1);
    }
}

/// Prints the scenario's line and answers whether it failed.
async fn report(name: &str, scenario: impl std::future::Future<Output = Outcome>) -> bool {
    let outcome = match tokio::time::timeout(SCENARIO_LIMIT, scenario).await {
        Ok(outcome) => outcome,
        Err(_) => Err(format!("no answer within {SCENARIO_LIMIT:?}")),
    };
    match outcome {
        Ok(()) => {
            println!("ok: rust grpc {name}");
            false
        }
        Err(detail) => {
            println!("FAIL: rust grpc {name}: {detail}");
            true
        }
    }
}

/// Reads every `<name>.binpb` file of the directory, sorted by name.
fn read_cases(dir: &str) -> Result<Vec<Case>, Box<dyn std::error::Error>> {
    let mut paths: Vec<_> = std::fs::read_dir(dir)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<_, _>>()?;
    paths.retain(|path| path.extension().is_some_and(|extension| extension == "binpb"));
    paths.sort();
    let mut cases = Vec::with_capacity(paths.len());
    for path in paths {
        let name = path.file_stem().unwrap_or_default().to_string_lossy().into_owned();
        let message = Everything::decode(std::fs::read(&path)?.as_slice())?;
        cases.push(Case { name, message });
    }
    if cases.is_empty() {
        return Err(format!("no .binpb files in {dir}").into());
    }
    Ok(cases)
}

/// Fails unless both messages encode to the same octets.
fn same<M: Message + std::fmt::Debug>(what: &str, want: &M, got: &M) -> Outcome {
    if want.encode_to_vec() == got.encode_to_vec() {
        Ok(())
    } else {
        Err(format!("{what} differs: want {want:?}, got {got:?}"))
    }
}

fn status_text(status: tonic::Status) -> String {
    format!("{:?}: {}", status.code(), status.message())
}

async fn echo(mut client: Client, message: &Everything) -> Outcome {
    let response = client.echo(message.clone()).await.map_err(status_text)?;
    same("the echo", message, response.get_ref())
}

async fn repeat(mut client: Client, cases: &[Case]) -> Outcome {
    let case = cases.iter().find(|case| case.name == REPEAT_CASE).unwrap_or(&cases[0]);
    let request = RepeatRequest { message: Some(case.message.clone()), count: REPEAT_COUNT };
    let mut stream = client.repeat(request).await.map_err(status_text)?.into_inner();
    let mut received = 0;
    while let Some(message) = stream.message().await.map_err(status_text)? {
        same(&format!("copy {received}"), &case.message, &message)?;
        received += 1;
    }
    if received != REPEAT_COUNT {
        return Err(format!("want {REPEAT_COUNT} copies, got {received}"));
    }
    Ok(())
}

async fn collect(mut client: Client, cases: &[Case]) -> Outcome {
    let messages: Vec<Everything> = cases.iter().map(|case| case.message.clone()).collect();
    let response = client
        .collect(tokio_stream::iter(messages))
        .await
        .map_err(status_text)?
        .into_inner();
    if response.count != cases.len() as i32 {
        return Err(format!("want count {}, got {}", cases.len(), response.count));
    }
    let last = &cases[cases.len() - 1].message;
    same("the last message", last, &response.last.unwrap_or_default())
}

/// Sends each case only after the echo of the one before it arrived, which needs full duplex.
async fn chat(mut client: Client, cases: &[Case]) -> Outcome {
    let (sender, receiver) = mpsc::channel(1);
    // The server may hold its response headers until the first message, so send it first.
    sender.send(cases[0].message.clone()).await.map_err(|error| error.to_string())?;
    let mut stream = client
        .chat(ReceiverStream::new(receiver))
        .await
        .map_err(status_text)?
        .into_inner();
    let mut sender = Some(sender);
    for (index, case) in cases.iter().enumerate() {
        let Some(message) = stream.message().await.map_err(status_text)? else {
            return Err(format!("the stream ended after {index} answers"));
        };
        same(&format!("answer to {}", case.name), &case.message, &message)?;
        match cases.get(index + 1) {
            Some(next) => {
                let open = sender.as_ref().expect("the sender stays open until the last case");
                open.send(next.message.clone()).await.map_err(|error| error.to_string())?;
            }
            None => sender = None,
        }
    }
    drop(sender);
    if let Some(extra) = stream.message().await.map_err(status_text)? {
        return Err(format!("an extra answer: {extra:?}"));
    }
    Ok(())
}

async fn fail(mut client: Client) -> Outcome {
    let request = FailRequest { code: Code::NotFound as i32, message: "gone".into() };
    let status = match client.fail(request.clone()).await {
        Ok(response) => return Err(format!("want an error, got {:?}", response.get_ref())),
        Err(status) => status,
    };
    if status.code() != Code::NotFound || status.message() != "gone" {
        return Err(format!("want NotFound \"gone\", got {}", status_text(status)));
    }
    let details = RpcStatus::decode(status.details()).map_err(|error| format!("details: {error}"))?;
    let [detail] = details.details.as_slice() else {
        return Err(format!("want one detail, got {}", details.details.len()));
    };
    if !detail.type_url.ends_with("/interop.v1.FailRequest") {
        return Err(format!("want a FailRequest detail, got {}", detail.type_url));
    }
    let held = FailRequest::decode(detail.value.as_slice()).map_err(|error| error.to_string())?;
    same("the detail", &request, &held)
}

/// Calls Inspect through the generic client as a server stream, which keeps the response
/// headers apart from the trailers; the generated unary call merges them.
async fn inspect(channel: Channel) -> Outcome {
    let mut grpc = tonic::client::Grpc::new(channel);
    grpc.ready().await.map_err(|error| error.to_string())?;
    let mut request = Request::new(InspectRequest {});
    request.set_timeout(INSPECT_TIMEOUT);
    request.metadata_mut().insert(CLIENT_HEADER, CLIENT_NAME.parse().expect("ASCII"));
    let path = "/interop.v1.InteropService/Inspect".parse().expect("a valid path");
    let codec = tonic_prost::ProstCodec::<InspectRequest, InspectResponse>::default();
    let response = grpc.server_streaming(request, path, codec).await.map_err(status_text)?;
    let header = response.metadata().get(CLIENT_HEADER).cloned();
    let mut stream = response.into_inner();
    let Some(answer) = stream.message().await.map_err(status_text)? else {
        return Err("no response message".into());
    };
    if stream.message().await.map_err(status_text)?.is_some() {
        return Err("more than one response message".into());
    }
    let trailers = stream.trailers().await.map_err(status_text)?.unwrap_or_default();
    let trailer = trailers.get(CLIENT_HEADER).cloned();
    let maximum_ms = INSPECT_TIMEOUT.as_millis() as i64;
    if answer.timeout_ms < 1 || answer.timeout_ms > maximum_ms {
        return Err(format!("want a timeout in 1..={maximum_ms} ms, got {}", answer.timeout_ms));
    }
    let seen = format!("{CLIENT_HEADER}: {CLIENT_NAME}");
    if !answer.headers.contains(&seen) {
        return Err(format!("want header {seen:?} seen, got {:?}", answer.headers));
    }
    if header.as_ref().and_then(|value| value.to_str().ok()) != Some(CLIENT_NAME) {
        return Err(format!("want response header {seen:?}, got {header:?}"));
    }
    if trailer.as_ref().and_then(|value| value.to_str().ok()) != Some(CLIENT_NAME) {
        return Err(format!("want trailer {seen:?}, got {trailer:?}"));
    }
    Ok(())
}
