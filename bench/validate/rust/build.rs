// Compiles bench.validate.v1 from the FileDescriptorSet that tools/validate_compare_check.sh
// names in VALIDATE_DESCRIPTORS, so the build needs no protoc:
//
// - Buffa's messages, then each message's validator, which protoc-gen-protovalidate-buffa's
//   library writes as the plugin does;
// - prost's messages, each deriving prost-reflect's ReflectMessage over the same set, as
//   prost-reflect-build's `configure` does with protoc.
use buffa::Message;
use buffa_codegen::generated::{compiler::CodeGeneratorRequest, descriptor::FileDescriptorSet};
use protoc_gen_protovalidate_buffa::{emit, scan};

const SCHEMA: &str = "bench/validate/v1/validate.proto";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-env-changed=VALIDATE_DESCRIPTORS");
    let path = std::env::var("VALIDATE_DESCRIPTORS")?;
    println!("cargo:rerun-if-changed={path}");
    buffa_build::Config::new()
        .descriptor_set(&path)
        .files(&[SCHEMA])
        .include_file("protos.rs")
        .compile()?;
    let set = FileDescriptorSet::decode_from_slice(&std::fs::read(&path)?)?;
    let request = CodeGeneratorRequest {
        file_to_generate: vec![SCHEMA.into()],
        proto_file: set.file,
        ..Default::default()
    };
    let validators = scan::gather(&request).map_err(|e| e.to_string())?;
    let options = emit::Options { proto_module: "crate::proto".into(), ..Default::default() };
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR")?).join("validators");
    std::fs::create_dir_all(&out)?;
    for file in emit::render_with_options(&validators, &options).map_err(|e| e.to_string())? {
        let name = file.name.unwrap_or_default();
        let target = out.join(&name);
        std::fs::create_dir_all(target.parent().unwrap())?;
        std::fs::write(&target, without_inner_attributes(&file.content.unwrap_or_default()))?;
    }
    compile_prost(&path)?;
    Ok(())
}

/// prost's messages of the schema, which prost-protovalidate reads through prost-reflect.
fn compile_prost(path: &str) -> Result<(), Box<dyn std::error::Error>> {
    use prost::Message as _;
    let bytes = std::fs::read(path)?;
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR")?);
    std::fs::write(out.join("file_descriptor_set.bin"), &bytes)?;
    let set = prost_types::FileDescriptorSet::decode(bytes.as_slice())?;
    let mut config = prost_build::Config::new();
    let schema = set.file.iter().find(|file| file.name() == SCHEMA).ok_or("the set holds no schema")?;
    for message in &schema.message_type {
        let full_name = format!("{}.{}", schema.package(), message.name());
        config
            .type_attribute(&full_name, "#[derive(::prost_reflect::ReflectMessage)]")
            .type_attribute(&full_name, format!(r#"#[prost_reflect(message_name = "{full_name}")]"#))
            .type_attribute(&full_name, r#"#[prost_reflect(file_descriptor_set_bytes = "crate::prost_proto::FILE_DESCRIPTOR_SET")]"#);
    }
    config.compile_fds(set)?;
    Ok(())
}

/// The file's text without its leading `#![allow(...)]`: an inner attribute may not stand in a
/// file that `include!` reads into a module, so src/main.rs states the same allowances on the
/// module.
fn without_inner_attributes(text: &str) -> String {
    let Some(start) = text.find("#![allow(") else { return text.to_string() };
    let end = text[start..].find(")]").map_or(start, |at| start + at + 2);
    format!("{}{}", &text[..start], &text[end..])
}
