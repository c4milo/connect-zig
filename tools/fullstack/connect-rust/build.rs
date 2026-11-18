// Compiles OpenTelemetry's trace export from the FileDescriptorSet that tools/fullstack_check.sh
// names in OTLP_DESCRIPTORS, so the build needs no protoc.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-env-changed=OTLP_DESCRIPTORS");
    let path = std::env::var("OTLP_DESCRIPTORS")?;
    println!("cargo:rerun-if-changed={path}");
    connectrpc_build::Config::new()
        .descriptor_set(path)
        .files(&[
            "opentelemetry/proto/common/v1/common.proto",
            "opentelemetry/proto/resource/v1/resource.proto",
            "opentelemetry/proto/trace/v1/trace.proto",
            "opentelemetry/proto/collector/trace/v1/trace_service.proto",
        ])
        .include_file("_connectrpc.rs")
        .compile()?;
    Ok(())
}
