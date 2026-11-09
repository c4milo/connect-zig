#!/bin/sh
# Serves the grpcio interop server for connect-zig's interop client (interop/README.md, "The
# server side").
# Usage: interop/python/serve.sh python <port> <chain> <key> <descriptors>
# It installs the pinned packages into the cache run.sh uses, and compiles examples/proto itself,
# so the descriptors go unused.
set -eu

if [ "$#" -ne 5 ] || [ "$1" != python ]; then
    echo "usage: $0 python <port> <chain> <key> <descriptors>" >&2
    exit 2
fi
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"
python="${PYTHON:-python3}"

# The virtualenv of run.sh: named after the requirements and the interpreter.
key="$({ cat "${here}/requirements.txt"; "${python}" --version; } | sha256sum | cut -c1-16)"
venv="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/interop-python-${key}"
if [ ! -f "${venv}/.installed" ]; then
    rm -rf "${venv}"
    "${python}" -m venv "${venv}"
    "${venv}/bin/pip" install --disable-pip-version-check --quiet \
        --require-hashes --only-binary=:all: -r "${here}/requirements.txt"
    touch "${venv}/.installed"
fi

# The generated code goes beside the virtualenv, so the server can replace this shell.
gen="${venv}-server-gen"
rm -rf "${gen}"
mkdir -p "${gen}"
"${venv}/bin/python" -m grpc_tools.protoc -I "${repo}/examples/proto" \
    --python_out="${gen}" --grpc_python_out="${gen}" \
    "${repo}/examples/proto/coverage/v1/coverage.proto" \
    "${repo}/examples/proto/interop/v1/interop.proto"

exec "${venv}/bin/python" -I "${here}/server.py" "${gen}" "$2" "$3" "$4"
