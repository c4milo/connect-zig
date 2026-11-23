// Compiles OpenTelemetry's trace export from the FileDescriptorSet that tools/fullstack_check.sh
// names in OTLP_DESCRIPTORS, so the build needs no protoc. The set is tools/fullstack/validate's
// copy of the schema, whose spans carry OTLP's rules: connect-rust's messages and service, then
// each message's validator, which protoc-gen-protovalidate-buffa's library writes as the plugin
// does, as bench/validate/rust builds them.
use buffa::Message;
use buffa_codegen::generated::{compiler::CodeGeneratorRequest, descriptor::FileDescriptorSet};
use protoc_gen_protovalidate_buffa::{emit, scan};

const FILES: [&str; 4] = [
    "opentelemetry/proto/common/v1/common.proto",
    "opentelemetry/proto/resource/v1/resource.proto",
    "opentelemetry/proto/trace/v1/trace.proto",
    "opentelemetry/proto/collector/trace/v1/trace_service.proto",
];

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-env-changed=OTLP_DESCRIPTORS");
    let path = std::env::var("OTLP_DESCRIPTORS")?;
    println!("cargo:rerun-if-changed={path}");
    connectrpc_build::Config::new()
        .descriptor_set(&path)
        .files(&FILES)
        .include_file("_connectrpc.rs")
        .compile()?;
    let set = FileDescriptorSet::decode_from_slice(&std::fs::read(&path)?)?;
    let request = CodeGeneratorRequest {
        file_to_generate: FILES.iter().map(|file| file.to_string()).collect(),
        proto_file: set.file,
        ..Default::default()
    };
    let validators = scan::gather(&request).map_err(|e| e.to_string())?;
    let options = emit::Options {
        proto_module: "crate::proto".into(),
        ..Default::default()
    };
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR")?).join("validators");
    std::fs::create_dir_all(&out)?;
    for file in emit::render_with_options(&validators, &options).map_err(|e| e.to_string())? {
        let name = file.name.unwrap_or_default();
        let target = out.join(&name);
        std::fs::create_dir_all(target.parent().unwrap())?;
        std::fs::write(
            &target,
            without_inner_attributes(&file.content.unwrap_or_default()),
        )?;
    }
    Ok(())
}

/// The file's text without its leading `#![allow(...)]`: an inner attribute may not stand in a
/// file that `include!` reads into a module, so src/main.rs states the same allowances on the
/// module.
fn without_inner_attributes(text: &str) -> String {
    let Some(start) = text.find("#![allow(") else {
        return text.to_string();
    };
    let end = text[start..].find(")]").map_or(start, |at| start + at + 2);
    format!("{}{}", &text[..start], &text[end..])
}
