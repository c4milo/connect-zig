// Compiles interop.v1 and coverage.v1 from the FileDescriptorSet that run.sh names in
// INTEROP_DESCRIPTORS, so the build needs no protoc. Well-known types come from buffa-types.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-env-changed=INTEROP_DESCRIPTORS");
    let path = std::env::var("INTEROP_DESCRIPTORS")?;
    println!("cargo:rerun-if-changed={path}");
    let mut buffa = connectrpc_build::CodeGenConfig::default();
    buffa.generate_json = true;
    // A BTreeMap writes map entries in key order, so two equal messages write the same octets.
    buffa
        .map_fields
        .push((".".into(), buffa_codegen::MapRepr::BTreeMap));
    connectrpc_build::Config::new()
        .buffa_config(buffa)
        .descriptor_set(path)
        .files(&["interop/v1/interop.proto", "coverage/v1/coverage.proto"])
        .include_file("_connectrpc.rs")
        .compile()?;
    Ok(())
}
