#!/bin/sh
# Every check of this repository, in the order a person runs them (CLAUDE.md, Commands). CI runs
# this script, so CI and a person run the same thing. Writes a report to $1 when given.
set -eu
report="${1:-/dev/null}"
cd "$(dirname "$0")/.."
run() {
    name="$1"
    shift
    echo "== ${name}"
    if "$@"; then
        echo "- ${name}: pass" >>"${report}"
    else
        echo "- ${name}: FAIL" >>"${report}"
        exit 1
    fi
}
echo "# connect-zig checks" >"${report}"
run format zig fmt --check build.zig build src tools examples
run test zig build test --summary all
run release zig build -Drelease
