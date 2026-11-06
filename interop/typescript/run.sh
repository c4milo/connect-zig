#!/bin/sh
# Runs the connect-es interop client against connect-zig's socket server (interop/README.md).
# Usage: interop/typescript/run.sh <base-url> <cases-dir> <descriptors> <ca>
# It installs the pinned packages with npm ci, generates gen/ with buf ("${BUF:-buf}"), and runs
# main.js on Node. The client compiles the schema from examples/proto, so it ignores <descriptors>.
set -eu

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <base-url> <cases-dir> <descriptors> <ca>" >&2
    exit 2
fi
base_url="$1"
cases_dir="$(cd "$2" && pwd)"
ca="$(cd "$(dirname "$4")" && pwd)/$(basename "$4")"

cd "$(dirname "$0")"
npm ci --silent --no-audit --no-fund >/dev/null
rm -rf gen
"${BUF:-buf}" generate
exec node main.js "${base_url}" "${cases_dir}" "${ca}"
