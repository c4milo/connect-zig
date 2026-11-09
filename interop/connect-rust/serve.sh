#!/bin/sh
# Serves the connect-rust interop server for connect-zig's interop client (interop/README.md,
# "The server side"). It builds the crate against the given descriptors, as run.sh does, into the
# same target directory, and runs it in its serve mode.
#
#   interop/connect-rust/serve.sh connect-rust <port> <chain> <key> <descriptors>
set -eu
[ "$#" -eq 5 ] && [ "$1" = connect-rust ] || {
    echo "usage: $0 connect-rust <port> <chain> <key> <descriptors>" >&2
    exit 2
}
here="$(cd "$(dirname "$0")" && pwd)"
INTEROP_DESCRIPTORS="$(cd "$(dirname "$5")" && pwd)/$(basename "$5")"
export INTEROP_DESCRIPTORS
CARGO_TARGET_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/connect-zig/interop-connect-rust-target"
export CARGO_TARGET_DIR
cargo build --quiet --locked --release --manifest-path "${here}/Cargo.toml"
exec "${CARGO_TARGET_DIR}/release/interop-connect-rust" serve "$2" "$3" "$4"
