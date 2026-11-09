//! The Rust counterpart of bench/main.zig and bench/go: Buffa on the same eight messages, timed
//! the same way, printed as the same Markdown table.
//!
//! tools/bench_check.sh builds and runs it from bench/rust, with BENCH_DESCRIPTORS naming the
//! descriptor set of bench/proto: `cargo run --release --locked -- [--quick] [--write <dir>]`.
//! A map field is a BTreeMap, so binary encoding writes map entries in key order, as the Zig
//! benchmark and Go's deterministic marshaling do. Encoding appends to a buffer the benchmark
//! keeps, as Zig writes into the caller's buffer. Binary decoding builds Buffa's zero-copy view,
//! whose strings and bytes point into the input, as Zig's do. JSON decoding builds the owned
//! message, the only form serde decodes JSON to, which copies every string.

use std::hint::black_box;
use std::path::Path;

use buffa::HasMessageView;
use serde::de::DeserializeOwned;
use serde::Serialize;

mod inputs;
mod measure;
mod walk;

#[allow(clippy::all)]
mod protos {
    include!(concat!(env!("OUT_DIR"), "/protos.rs"));
}

use measure::{Run, Settings};
use walk::Walk;

const BYTES_PER_MEGABYTE: f64 = 1_000_000.0;
const NANOSECONDS_PER_SECOND: f64 = 1e9;

const OPERATIONS: [&str; 6] = [
    "binary encode",
    "binary decode",
    "binary decode+walk",
    "JSON encode",
    "JSON decode",
    "JSON decode+walk",
];

/// A benchmark message, its two encodings, and the sum its walk gives.
struct Case<T> {
    name: &'static str,
    input: T,
    binary: Vec<u8>,
    json: Vec<u8>,
    sum: u64,
}

/// What the benchmark needs of a generated message: binary and JSON codecs, a view, and a walk
/// over both.
trait Benched: HasMessageView + Walk + Serialize + DeserializeOwned
where
    for<'a> Self::View<'a>: Walk,
{
}

impl<T> Benched for T
where
    T: HasMessageView + Walk + Serialize + DeserializeOwned,
    for<'a> T::View<'a>: Walk,
{
}

fn main() {
    let mut current = &measure::FULL;
    let mut directory: Option<String> = None;
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--quick" => current = &measure::QUICK,
            "--write" => directory = arguments.next(),
            _ => {
                eprintln!("usage: bench-rust [--quick] [--write <dir>]");
                std::process::exit(2);
            }
        }
    }
    if let Err(error) = run(current, directory.as_deref()) {
        eprintln!("bench: {error}");
        std::process::exit(1);
    }
}

fn run(current: &Settings, directory: Option<&str>) -> Result<(), String> {
    print!("| message | operation | bytes | ns/op | MB/s |\n| --- | --- | ---: | ---: | ---: |\n");
    bench(current, directory, "small", inputs::small())?;
    bench(current, directory, "medium", inputs::medium())?;
    bench(current, directory, "large", inputs::large())?;
    bench(current, directory, "deep", inputs::deep())?;
    bench(current, directory, "varints", inputs::varints())?;
    bench(current, directory, "strings", inputs::strings())?;
    bench(
        current,
        directory,
        "tree",
        inputs::tree(inputs::TREE_LEVELS_COUNT),
    )?;
    bench(current, directory, "packed", inputs::packed())
}

fn bench<T: Benched>(
    current: &Settings,
    directory: Option<&str>,
    name: &'static str,
    input: T,
) -> Result<(), String>
where
    for<'a> T::View<'a>: Walk,
{
    let case = prepare(name, input).map_err(|error| format!("{name}: {error}"))?;
    if let Some(directory) = directory {
        case.write(Path::new(directory))
            .map_err(|error| format!("{name}: {error}"))?;
    }
    for operation in OPERATIONS {
        let mut runner = case.runner(operation);
        let ns = measure::median_ns(current, &mut runner)
            .map_err(|error| format!("{name}, {operation}: {error}"))?;
        let size = if operation.starts_with('J') {
            case.json.len()
        } else {
            case.binary.len()
        };
        let megabytes_per_second = size as f64 / ns * NANOSECONDS_PER_SECOND / BYTES_PER_MEGABYTE;
        println!("| {name} | {operation} | {size} | {ns:.1} | {megabytes_per_second:.1} |");
    }
    Ok(())
}

/// Encodes the message once in each form, and checks that both decode back to it.
fn prepare<T: Benched>(name: &'static str, input: T) -> Result<Case<T>, String>
where
    for<'a> T::View<'a>: Walk,
{
    let binary = input.encode_to_vec();
    let json = serde_json::to_vec(&input).map_err(|error| error.to_string())?;
    let sum = input.walk();
    let decoded = T::decode_from_slice(&binary).map_err(|error| error.to_string())?;
    let view_sum = T::decode_view(&binary)
        .map_err(|error| error.to_string())?
        .walk();
    if decoded.walk() != sum || view_sum != sum || decoded.encode_to_vec() != binary {
        return Err("the binary encoding does not decode back to the message".into());
    }
    let from_json: T = serde_json::from_slice(&json).map_err(|error| error.to_string())?;
    if from_json.walk() != sum {
        return Err("the JSON encoding does not decode back to the message".into());
    }
    Ok(Case {
        name,
        input,
        binary,
        json,
        sum,
    })
}

impl<T: Benched> Case<T>
where
    for<'a> T::View<'a>: Walk,
{
    fn write(&self, directory: &Path) -> std::io::Result<()> {
        std::fs::create_dir_all(directory)?;
        std::fs::write(directory.join(format!("{}.bin", self.name)), &self.binary)?;
        std::fs::write(
            directory.join(format!("{}.sum", self.name)),
            format!("{}\n", self.sum),
        )
    }

    /// Returns a function that runs the operation n times.
    fn runner(&self, operation: &str) -> Run<'_> {
        match operation {
            "binary encode" => {
                let mut buffer = Vec::with_capacity(self.binary.len());
                Box::new(move |n| {
                    for _ in 0..n {
                        buffer.clear();
                        self.input.encode(&mut buffer);
                        black_box(buffer.len());
                    }
                    Ok(())
                })
            }
            "binary decode" | "binary decode+walk" => {
                let walk = operation == "binary decode+walk";
                Box::new(move |n| {
                    for _ in 0..n {
                        let view = T::decode_view(black_box(&self.binary))
                            .map_err(|error| error.to_string())?;
                        if walk {
                            black_box(view.walk());
                        }
                        black_box(&view);
                    }
                    Ok(())
                })
            }
            "JSON encode" => {
                let mut buffer = Vec::with_capacity(self.json.len());
                Box::new(move |n| {
                    for _ in 0..n {
                        buffer.clear();
                        serde_json::to_writer(&mut buffer, &self.input)
                            .map_err(|error| error.to_string())?;
                        black_box(buffer.len());
                    }
                    Ok(())
                })
            }
            _ => {
                let walk = operation == "JSON decode+walk";
                Box::new(move |n| {
                    for _ in 0..n {
                        let decoded: T = serde_json::from_slice(black_box(&self.json))
                            .map_err(|error| error.to_string())?;
                        if walk {
                            black_box(decoded.walk());
                        }
                        black_box(&decoded);
                    }
                    Ok(())
                })
            }
        }
    }
}
