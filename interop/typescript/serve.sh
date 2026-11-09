#!/bin/sh
# Serves the connect-node interop server for connect-zig's interop client (interop/README.md,
# "The server side"). It installs the pinned packages with npm ci, generates gen/ with buf
# ("${BUF:-buf}"), and runs server.js on Node. The descriptors go unused.
# Usage: interop/typescript/serve.sh typescript <port> <chain> <key> <descriptors>
set -eu

if [ "$#" -ne 5 ] || [ "$1" != typescript ]; then
    echo "usage: $0 typescript <port> <chain> <key> <descriptors>" >&2
    exit 2
fi
chain="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
key="$(cd "$(dirname "$4")" && pwd)/$(basename "$4")"

cd "$(dirname "$0")"
npm ci --silent --no-audit --no-fund >/dev/null
rm -rf gen
"${BUF:-buf}" generate
exec node server.js "$2" "${chain}" "${key}"
