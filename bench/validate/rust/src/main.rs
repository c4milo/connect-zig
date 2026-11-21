//! The validation benchmark's Rust program (tools/validate_compare_check.sh): two libraries over
//! the schema of bench/validate/proto. protovalidate-buffa runs the validators its plugin wrote
//! as Rust code, on Buffa's messages. prost-protovalidate reads each message's rules through
//! prost-reflect and runs its CEL in an interpreter, on prost's messages.
//!
//!     validate-rust [--quick] [--prost] <directory>
//!
//! With `--prost` it times prost-protovalidate, and protovalidate-buffa without it.
//!
//! It reads each case's encoded message from the directory, as bench/validate_main.zig does, and
//! times two things, the median nanoseconds of one call of each: `validate` of the message
//! decoded once, and the decode of its octets with `validate` of what it gives. It prints a row
//! for each case with its verdict: "valid", or "invalid:" and the rule ids of the violations in
//! order.

mod measure;

#[allow(clippy::all)]
mod proto {
    include!(concat!(env!("OUT_DIR"), "/protos.rs"));
}

#[allow(clippy::all, non_camel_case_types, dead_code, unused_imports)]
mod validators {
    include!(concat!(env!("OUT_DIR"), "/validators/mod.rs"));
}

#[allow(clippy::all)]
mod prost_proto {
    pub const FILE_DESCRIPTOR_SET: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/file_descriptor_set.bin"));
    include!(concat!(env!("OUT_DIR"), "/bench.validate.v1.rs"));
}

use buffa::Message;
use proto::bench::validate::v1::{Medium, Rules, Small};
use protovalidate_buffa::Validate;

/// "valid", or "invalid:" and the rule id of each violation, in order.
fn verdict_of(message: &impl Validate) -> String {
    match message.validate() {
        Ok(()) => "valid".into(),
        Err(error) => {
            let mut ids: Vec<String> = error.violations.iter().map(|violation| violation.rule_id.to_string()).collect();
            ids.sort();
            format!("invalid:{}", ids.join(","))
        }
    }
}

fn row<M: Message + Validate + Default>(settings: &measure::Settings, directory: &str, name: &str, file: &str) -> Result<String, String> {
    let bytes = std::fs::read(format!("{directory}/{file}")).map_err(|e| e.to_string())?;
    let message = M::decode_from_slice(&bytes).map_err(|e| e.to_string())?;
    let verdict = verdict_of(&message);
    let mut run: measure::Run<'_> = Box::new(|n| {
        for _ in 0..n {
            std::hint::black_box(std::hint::black_box(&message).validate().is_ok());
        }
        Ok(())
    });
    let ns = measure::median_ns(settings, &mut run)?;
    let mut both: measure::Run<'_> = Box::new(|n| {
        for _ in 0..n {
            let fresh = M::decode_from_slice(std::hint::black_box(&bytes)).map_err(|e| e.to_string())?;
            std::hint::black_box(fresh.validate().is_ok());
        }
        Ok(())
    });
    let both_ns = measure::median_ns(settings, &mut both)?;
    Ok(format!("| {name} | {verdict} | {ns:.1} | {both_ns:.1} |"))
}

/// The same row for prost-protovalidate: one `Validator` for every call, as a server keeps one,
/// which caches each type's compiled rules.
fn prost_row<M: prost::Message + prost_reflect::ReflectMessage + Default>(
    settings: &measure::Settings,
    validator: &prost_protovalidate::Validator,
    directory: &str,
    name: &str,
    file: &str,
) -> Result<String, String> {
    let bytes = std::fs::read(format!("{directory}/{file}")).map_err(|e| e.to_string())?;
    let message = M::decode(bytes.as_slice()).map_err(|e| e.to_string())?;
    let verdict = match validator.validate(&message) {
        Ok(()) => "valid".to_string(),
        Err(prost_protovalidate::Error::Validation(error)) => {
            let mut ids: Vec<String> = error.violations().iter().map(|violation| violation.rule_id().to_string()).collect();
            ids.sort();
            format!("invalid:{}", ids.join(","))
        }
        Err(other) => format!("error:{other}"),
    };
    let mut run: measure::Run<'_> = Box::new(|n| {
        for _ in 0..n {
            std::hint::black_box(validator.validate(std::hint::black_box(&message)).is_ok());
        }
        Ok(())
    });
    let ns = measure::median_ns(settings, &mut run)?;
    let mut both: measure::Run<'_> = Box::new(|n| {
        for _ in 0..n {
            let fresh = M::decode(std::hint::black_box(bytes.as_slice())).map_err(|e| e.to_string())?;
            std::hint::black_box(validator.validate(&fresh).is_ok());
        }
        Ok(())
    });
    let both_ns = measure::median_ns(settings, &mut both)?;
    Ok(format!("| {name} | {verdict} | {ns:.1} | {both_ns:.1} |"))
}

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let settings = if args.iter().any(|arg| arg == "--quick") { &measure::QUICK } else { &measure::FULL };
    let library = args.iter().any(|arg| arg == "--prost");
    let directory = args.iter().find(|arg| !arg.starts_with("--")).ok_or("usage: validate-rust [--quick] [--prost] <directory>")?;
    println!("| case | verdict | validate ns/op | decode and validate ns/op |\n| --- | --- | ---: | ---: |");
    if library {
        let validator = prost_protovalidate::Validator::new();
        use prost_proto::{Medium, Rules, Small};
        for (name, file, row) in [
            ("small valid", "small_valid.binpb", prost_row::<Small> as fn(_, _, _, _, _) -> _),
            ("small invalid", "small_invalid.binpb", prost_row::<Small>),
            ("medium valid", "medium_valid.binpb", prost_row::<Medium>),
            ("medium invalid", "medium_invalid.binpb", prost_row::<Medium>),
            ("rules valid", "rules_valid.binpb", prost_row::<Rules>),
            ("rules invalid", "rules_invalid.binpb", prost_row::<Rules>),
        ] {
            println!("{}", row(settings, &validator, directory, name, file)?);
        }
        return Ok(());
    }
    println!("{}", row::<Small>(settings, directory, "small valid", "small_valid.binpb")?);
    println!("{}", row::<Small>(settings, directory, "small invalid", "small_invalid.binpb")?);
    println!("{}", row::<Medium>(settings, directory, "medium valid", "medium_valid.binpb")?);
    println!("{}", row::<Medium>(settings, directory, "medium invalid", "medium_invalid.binpb")?);
    println!("{}", row::<Rules>(settings, directory, "rules valid", "rules_valid.binpb")?);
    println!("{}", row::<Rules>(settings, directory, "rules invalid", "rules_invalid.binpb")?);
    Ok(())
}
