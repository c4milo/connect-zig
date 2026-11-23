//! The load of tools/fullstack/production.sh: OTLP's `TraceService/Export` over gRPC at fixed
//! rates, on connections that stay open across the steps of a climb.
//!
//!     fullstack-load --address <host:port> --path <path> [--ca <ca.pem>] [--encoding <coding>]
//!                    [--streams <n>] [--threads <n>] --class <spans>:<connections>:<file>,<file>...
//!
//! It opens every class's connections once, over TLS offering AES-128-GCM alone when `--ca` names
//! the test CA, or over cleartext h2. It offers TLS 1.3 and TLS 1.2, since Vector's listener speaks
//! TLS 1.2 alone. It then prints `ready <connections>
//! <suite>`, and reads one command a line from standard input:
//!
//! - `step <rate> <seconds> <dir>`: each connection sends <rate> exports a second for <seconds>,
//!   one at each tick of its own schedule, with at most <streams> calls in flight. Each class's
//!   connections spread their schedules evenly over the interval of a tick, so each class's calls
//!   arrive at an even rate, and a step of any length sends each class its share.
//!   A call that waits for a free stream counts that wait in its latency, which runs from its
//!   tick: the load stays open, as oha's latency correction keeps it. The step writes
//!   `<dir>/step-<spans>.csv` for each class, which tools/fullstack/production_step.py reads, and
//!   prints `done <calls> <reopened>`. Before the step it opens again each connection the server
//!   closed, as an agent would, and <reopened> counts them.
//! - `quit`: it closes its connections and ends.
//!
//! Each call sends the class's files in turn, so a decoder never reads the same octets twice in a
//! row. A call counts as `200` when the server answers HTTP 200 and grpc-status 0 (gRPC over
//! HTTP/2, "Responses"); any other answer names what came back.

use std::io::BufRead;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use h2::client::SendRequest;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;
use tokio::time::{sleep_until, timeout, Instant};
use tokio_rustls::rustls;

/// How long after a step ends a call may still answer before it counts as lost.
const CALL_GRACE: Duration = Duration::from_secs(60);
/// The delay between a step's command and its first tick, so every connection's task starts
/// before its schedule does.
const STEP_LEAD: Duration = Duration::from_millis(200);
/// How long a connection may take to offer a stream between steps, when none is in flight, before
/// it counts as closed.
const READY_WAIT: Duration = Duration::from_secs(1);

struct Options {
    address: String,
    path: String,
    ca: Option<String>,
    encoding: Option<String>,
    streams: usize,
    threads: usize,
    classes: Vec<ClassOption>,
}

struct ClassOption {
    spans: u32,
    connections: usize,
    files: Vec<String>,
}

/// One class's exports, each the octets of a gRPC Length-Prefixed-Message.
struct Class {
    spans: u32,
    bodies: Vec<Bytes>,
}

/// A connection, the class it sends, its place among its class's connections, and the share of a
/// tick's interval its schedule waits after a step's start.
struct Connection {
    sender: SendRequest<Bytes>,
    class: usize,
    place: usize,
    phase: f64,
}

/// A call: its tick in seconds after the step's start, its duration in seconds from its tick, and
/// what the server answered.
type Record = (f64, f64, String);

/// What one step's connections share.
struct Step {
    start: Instant,
    end: Instant,
    interval: Duration,
    uri: Arc<String>,
    encoding: Option<Arc<String>>,
    streams: usize,
}

fn main() {
    let options = match parse(std::env::args().skip(1).collect()) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("fullstack-load: {message}");
            std::process::exit(2);
        }
    };
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(options.threads)
        .enable_all()
        .build()
        .expect("a runtime of the asked threads");
    if let Err(message) = runtime.block_on(run(options)) {
        eprintln!("fullstack-load: {message}");
        std::process::exit(1);
    }
}

fn parse(arguments: Vec<String>) -> Result<Options, String> {
    let mut options = Options {
        address: String::new(),
        path: String::new(),
        ca: None,
        encoding: None,
        streams: 4,
        threads: 2,
        classes: Vec::new(),
    };
    let mut words = arguments.into_iter();
    while let Some(flag) = words.next() {
        let value = words.next().ok_or(format!("{flag} takes a value"))?;
        match flag.as_str() {
            "--address" => options.address = value,
            "--path" => options.path = value,
            "--ca" => options.ca = Some(value),
            "--encoding" => options.encoding = Some(value).filter(|coding| !coding.is_empty()),
            "--streams" => options.streams = value.parse().map_err(|_| "--streams takes a count")?,
            "--threads" => options.threads = value.parse().map_err(|_| "--threads takes a count")?,
            "--class" => options.classes.push(parse_class(&value)?),
            _ => return Err(format!("no flag {flag}")),
        }
    }
    if options.address.is_empty() || options.path.is_empty() || options.classes.is_empty() {
        return Err("--address, --path and --class are required".into());
    }
    Ok(options)
}

fn parse_class(value: &str) -> Result<ClassOption, String> {
    let mut parts = value.splitn(3, ':');
    let spans = parts
        .next()
        .and_then(|part| part.parse().ok())
        .ok_or("--class takes <spans>:")?;
    let connections = parts
        .next()
        .and_then(|part| part.parse().ok())
        .ok_or("--class takes :<connections>:")?;
    let files: Vec<String> = parts
        .next()
        .unwrap_or("")
        .split(',')
        .filter(|file| !file.is_empty())
        .map(String::from)
        .collect();
    if files.is_empty() {
        return Err(format!("--class {value} names no file"));
    }
    Ok(ClassOption {
        spans,
        connections,
        files,
    })
}

async fn run(options: Options) -> Result<(), String> {
    let classes = read_classes(&options)?;
    let tls = match &options.ca {
        Some(ca) => Some(connector(ca)?),
        None => None,
    };
    let mut connections = Vec::new();
    let mut suite = String::from("cleartext");
    for (class, option) in options.classes.iter().enumerate() {
        for place in 0..option.connections {
            let (sender, chosen) = connect(&options.address, &tls).await?;
            suite = chosen;
            // Each class spreads its schedules over the interval apart from the others, so a step
            // sends each class its share of calls, whatever the step's length.
            let phase = (place as f64 + 0.5) / option.connections as f64;
            connections.push(Connection {
                sender,
                class,
                place,
                phase,
            });
        }
    }
    println!("ready {} {suite}", connections.len());
    let scheme = if tls.is_some() { "https" } else { "http" };
    let uri = Arc::new(format!("{scheme}://{}{}", options.address, options.path));
    let encoding = options.encoding.clone().map(Arc::new);
    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let line = line.map_err(|error| error.to_string())?;
        let words: Vec<&str> = line.split_whitespace().collect();
        match words.as_slice() {
            ["step", rate, seconds, dir] => {
                let rate: f64 = rate.parse().map_err(|_| format!("no rate in {line}"))?;
                let seconds: f64 = seconds.parse().map_err(|_| format!("no seconds in {line}"))?;
                let reopened = reopen(&mut connections, &options.address, &tls).await?;
                let records = step(&connections, &classes, rate, seconds, &uri, &encoding, options.streams).await;
                let calls = write_records(dir, &classes, &records)?;
                println!("done {calls} {reopened}");
            }
            ["quit"] => break,
            _ => return Err(format!("no command {line}")),
        }
    }
    Ok(())
}

/// Opens again each connection that offers no stream, and gives how many it opened.
async fn reopen(
    connections: &mut [Connection],
    address: &str,
    tls: &Option<tokio_rustls::TlsConnector>,
) -> Result<usize, String> {
    let mut reopened = 0;
    for connection in connections.iter_mut() {
        if let Ok(Ok(_)) = timeout(READY_WAIT, connection.sender.clone().ready()).await {
            continue;
        }
        connection.sender = connect(address, tls).await?.0;
        reopened += 1;
    }
    Ok(reopened)
}

fn read_classes(options: &Options) -> Result<Vec<Class>, String> {
    options
        .classes
        .iter()
        .map(|option| {
            let bodies = option
                .files
                .iter()
                .map(|file| {
                    std::fs::read(file)
                        .map(Bytes::from)
                        .map_err(|error| format!("{file}: {error}"))
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Class {
                spans: option.spans,
                bodies,
            })
        })
        .collect()
}

/// AES-128-GCM alone, so every server runs the same cipher: TLS_AES_128_GCM_SHA256 in TLS 1.3, and
/// for a server of TLS 1.2 alone, as Vector's listener is, the same cipher with ECDHE. h2 by ALPN,
/// and the test CA as the only root.
fn connector(ca: &str) -> Result<tokio_rustls::TlsConnector, String> {
    let file = std::fs::File::open(ca).map_err(|error| format!("{ca}: {error}"))?;
    let mut roots = rustls::RootCertStore::empty();
    for certificate in rustls_pemfile::certs(&mut std::io::BufReader::new(file)) {
        let certificate = certificate.map_err(|error| format!("{ca}: {error}"))?;
        roots.add(certificate).map_err(|error| format!("{ca}: {error}"))?;
    }
    let mut provider = rustls::crypto::ring::default_provider();
    provider.cipher_suites = vec![
        rustls::crypto::ring::cipher_suite::TLS13_AES_128_GCM_SHA256,
        rustls::crypto::ring::cipher_suite::TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
        rustls::crypto::ring::cipher_suite::TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
    ];
    let mut config = rustls::ClientConfig::builder_with_provider(Arc::new(provider))
        .with_protocol_versions(&[&rustls::version::TLS13, &rustls::version::TLS12])
        .map_err(|error| error.to_string())?
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.alpn_protocols = vec![b"h2".to_vec()];
    Ok(tokio_rustls::TlsConnector::from(Arc::new(config)))
}

async fn connect(
    address: &str,
    tls: &Option<tokio_rustls::TlsConnector>,
) -> Result<(SendRequest<Bytes>, String), String> {
    let tcp = TcpStream::connect(address)
        .await
        .map_err(|error| format!("{address}: {error}"))?;
    tcp.set_nodelay(true).map_err(|error| error.to_string())?;
    let Some(connector) = tls else {
        return Ok((handshake(tcp).await?, String::from("cleartext")));
    };
    let host = address.rsplit_once(':').map_or(address, |(host, _)| host);
    let name = match host.parse::<IpAddr>() {
        Ok(ip) => rustls::pki_types::ServerName::IpAddress(ip.into()),
        Err(_) => rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|error| error.to_string())?,
    };
    let stream = connector
        .connect(name, tcp)
        .await
        .map_err(|error| format!("TLS: {error}"))?;
    let suite = stream
        .get_ref()
        .1
        .negotiated_cipher_suite()
        .and_then(|suite| suite.suite().as_str())
        // rustls names TLS 1.3's suites TLS13_; RFC 8446 §B.4 names them TLS_.
        .map_or_else(|| String::from("unknown"), |name| name.replacen("TLS13_", "TLS_", 1));
    Ok((handshake(stream).await?, suite))
}

/// h2's handshake over the connection, whose frames a task of their own then drive.
async fn handshake<T: AsyncRead + AsyncWrite + Unpin + Send + 'static>(io: T) -> Result<SendRequest<Bytes>, String> {
    let (sender, connection) = h2::client::handshake(io)
        .await
        .map_err(|error| format!("h2: {error}"))?;
    tokio::spawn(async move {
        let _ = connection.await;
    });
    Ok(sender)
}

async fn step(
    connections: &[Connection],
    classes: &[Class],
    rate: f64,
    seconds: f64,
    uri: &Arc<String>,
    encoding: &Option<Arc<String>>,
    streams: usize,
) -> Vec<Vec<Record>> {
    let start = Instant::now() + STEP_LEAD;
    let shared = Arc::new(Step {
        start,
        end: start + Duration::from_secs_f64(seconds),
        interval: Duration::from_secs_f64(1.0 / rate),
        uri: uri.clone(),
        encoding: encoding.clone(),
        streams,
    });
    let records: Arc<Vec<Mutex<Vec<Record>>>> = Arc::new(classes.iter().map(|_| Mutex::new(Vec::new())).collect());
    let mut drivers = JoinSet::new();
    for connection in connections {
        let bodies = classes[connection.class].bodies.clone();
        let schedule = Schedule {
            class: connection.class,
            place: connection.place,
            phase: connection.phase,
        };
        drivers.spawn(drive(
            connection.sender.clone(),
            schedule,
            bodies,
            shared.clone(),
            records.clone(),
        ));
    }
    while drivers.join_next().await.is_some() {}
    records
        .iter()
        .map(|class| std::mem::take(&mut *class.lock().expect("records")))
        .collect()
}

/// Where a connection's calls fall in a step: its class, its place in the class, and its phase.
struct Schedule {
    class: usize,
    place: usize,
    phase: f64,
}

/// One connection's calls in a step: one at each tick, each with a free stream.
async fn drive(
    sender: SendRequest<Bytes>,
    schedule: Schedule,
    bodies: Vec<Bytes>,
    step: Arc<Step>,
    records: Arc<Vec<Mutex<Vec<Record>>>>,
) {
    let Schedule { class, place, phase } = schedule;
    let streams = Arc::new(Semaphore::new(step.streams));
    let offset = step.interval.mul_f64(phase);
    let mut calls = JoinSet::new();
    for tick in 0u32.. {
        let due = step.start + offset + step.interval * tick;
        if due >= step.end {
            break;
        }
        sleep_until(due).await;
        let permit = streams
            .clone()
            .acquire_owned()
            .await
            .expect("the stream gate stays open");
        let body = bodies[(place + tick as usize) % bodies.len()].clone();
        let (sender, step) = (sender.clone(), step.clone());
        calls.spawn(async move {
            let status = match timeout(step.end - Instant::now() + CALL_GRACE, call(sender, &step, body)).await {
                Ok(status) => status,
                Err(_) => String::from("timeout"),
            };
            drop(permit);
            let ended = Instant::now();
            ((due - step.start).as_secs_f64(), (ended - due).as_secs_f64(), status)
        });
    }
    let mut done = Vec::new();
    while let Some(result) = calls.join_next().await {
        if let Ok(record) = result {
            done.push(record);
        }
    }
    records[class].lock().expect("records").extend(done);
}

/// One export: its request, its message, and the status of the answer.
async fn call(sender: SendRequest<Bytes>, step: &Step, body: Bytes) -> String {
    let mut ready = match sender.ready().await {
        Ok(ready) => ready,
        Err(_) => return String::from("error"),
    };
    let mut request = http::Request::post(step.uri.as_str())
        .header("content-type", "application/grpc")
        .header("te", "trailers");
    if let Some(coding) = &step.encoding {
        request = request.header("grpc-encoding", coding.as_str());
    }
    let request = request.body(()).expect("a request of fixed parts");
    let (response, mut stream) = match ready.send_request(request, false) {
        Ok(sent) => sent,
        Err(_) => return String::from("error"),
    };
    if stream.send_data(body, true).is_err() {
        return String::from("error");
    }
    match response.await {
        Ok(response) => answer(response).await,
        Err(_) => String::from("error"),
    }
}

/// The answer's status: `200` for HTTP 200 with grpc-status 0, in the trailers or, for an answer
/// of trailers alone, in the headers.
async fn answer(response: http::Response<h2::RecvStream>) -> String {
    let status = response.status();
    let early = grpc_status(response.headers());
    let mut body = response.into_body();
    while let Some(chunk) = body.data().await {
        match chunk {
            Ok(chunk) => {
                let _ = body.flow_control().release_capacity(chunk.len());
            }
            Err(_) => return String::from("error"),
        }
    }
    let late = match body.trailers().await {
        Ok(Some(trailers)) => grpc_status(&trailers),
        _ => None,
    };
    if status != http::StatusCode::OK {
        return status.as_u16().to_string();
    }
    match late.or(early) {
        Some(code) if code == "0" => String::from("200"),
        Some(code) => format!("grpc-{code}"),
        None => String::from("grpc-none"),
    }
}

fn grpc_status(headers: &http::HeaderMap) -> Option<String> {
    headers
        .get("grpc-status")
        .and_then(|value| value.to_str().ok())
        .map(String::from)
}

/// Each class's records as `<dir>/step-<spans>.csv`, and the calls of every class.
fn write_records(dir: &str, classes: &[Class], records: &[Vec<Record>]) -> Result<usize, String> {
    let mut calls = 0;
    for (class, rows) in classes.iter().zip(records) {
        let path = format!("{dir}/step-{}.csv", class.spans);
        let mut text = String::from("request-start,request-duration,status\n");
        for (start, duration, status) in rows {
            text.push_str(&format!("{start:.6},{duration:.6},{status}\n"));
        }
        std::fs::write(&path, text).map_err(|error| format!("{path}: {error}"))?;
        calls += rows.len();
    }
    Ok(calls)
}
