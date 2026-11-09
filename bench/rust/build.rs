// Compiles bench.v1 from the FileDescriptorSet that tools/bench_check.sh names in
// BENCH_DESCRIPTORS, so the build needs no protoc.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-env-changed=BENCH_DESCRIPTORS");
    let path = std::env::var("BENCH_DESCRIPTORS")?;
    println!("cargo:rerun-if-changed={path}");
    buffa_build::Config::new()
        .descriptor_set(path)
        .files(&["bench/v1/bench.proto"])
        .generate_json(true)
        // A BTreeMap writes map entries in key order, as Go's deterministic marshaling does.
        .map_type(buffa_build::MapRepr::BTreeMap)
        .include_file("protos.rs")
        .compile()
}
