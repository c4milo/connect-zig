#!/bin/sh
# Regenerates examples/gen and bench/gen with `buf generate` and the plugin this tree builds, into
# a temporary directory, and fails when either differs from the committed code (design §8 step 6).
# With --write it rewrites both instead. It needs buf on the path, or BUF naming it.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
zig build
# Each output directory, and the template that writes it.
targets="examples/gen:buf.gen.yaml bench/gen:bench/buf.gen.yaml"
if [ "${1:-}" = "--write" ]; then
    for target in ${targets}; do
        rm -rf "${target%%:*}"
        "${buf}" generate --template "${target#*:}"
    done
    exit 0
fi
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
for target in ${targets}; do
    directory="${target%%:*}"
    "${buf}" generate --template "${target#*:}" --output "${scratch}"
    if ! diff -r "${directory}" "${scratch}/${directory}"; then
        echo "${directory} differs from what buf generate writes; run tools/generate_check.sh --write" >&2
        exit 1
    fi
    echo "${directory} matches buf generate"
done
