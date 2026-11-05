// Compiles interop.v1 and coverage.v1 from the FileDescriptorSet that run.sh names in
// INTEROP_DESCRIPTORS, so the build needs no protoc.
use prost::Message;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-env-changed=INTEROP_DESCRIPTORS");
    let path = std::env::var("INTEROP_DESCRIPTORS")?;
    println!("cargo:rerun-if-changed={path}");
    let mut descriptors = prost_types::FileDescriptorSet::decode(std::fs::read(&path)?.as_slice())?;
    // Keep the two packages the client calls and the well-known types they import; prost
    // cannot read the editions files of the set.
    let wanted = ["interop/v1/", "coverage/v1/", "google/protobuf/"];
    descriptors.file.retain(|file| wanted.iter().any(|prefix| file.name().starts_with(prefix)));
    tonic_prost_build::configure()
        .build_server(false)
        // BTreeMap keeps map fields in key order, so encoding is deterministic.
        .btree_map(".")
        // Well-known types come from prost-types.
        .compile_well_known_types(false)
        .include_file("protos.rs")
        .compile_fds(descriptors)?;
    Ok(())
}
