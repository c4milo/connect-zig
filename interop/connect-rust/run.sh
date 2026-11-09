#!/bin/sh
# Builds the connect-rust client against the given descriptors and runs every scenario in
# Connect, gRPC and gRPC-Web (interop/README.md).
#
#   interop/connect-rust/run.sh <base-url> <cases-dir> <descriptors> <ca>
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
base_url="$1"
cases_dir="$2"
INTEROP_DESCRIPTORS="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
export INTEROP_DESCRIPTORS
CARGO_TARGET_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/connect-zig/interop-connect-rust-target"
export CARGO_TARGET_DIR
cargo build --quiet --locked --release --manifest-path "${here}/Cargo.toml"
exec "${CARGO_TARGET_DIR}/release/interop-connect-rust" "${base_url}" "${cases_dir}" "$4"
