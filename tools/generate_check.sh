#!/bin/sh
# Regenerates examples/gen with `buf generate` and the plugin this tree builds, into a temporary
# directory, and fails when it differs from the committed code (design §8 step 6). With --write it
# rewrites examples/gen instead. It needs buf on the path, or BUF naming it.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
zig build
if [ "${1:-}" = "--write" ]; then
    rm -rf examples/gen
    "${buf}" generate
    exit 0
fi
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
"${buf}" generate --output "${scratch}"
if ! diff -r examples/gen "${scratch}/examples/gen"; then
    echo "examples/gen differs from what buf generate writes; run tools/generate_check.sh --write" >&2
    exit 1
fi
echo "examples/gen matches buf generate"
