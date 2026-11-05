#!/bin/sh
# Runs the grpcio interop client against a connect-zig server.
# Usage: interop/python/run.sh <base-url> <cases-dir> <descriptors>
# The descriptors go unused: grpcio-tools compiles examples/proto itself.
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <base-url> <cases-dir> <descriptors>" >&2
    exit 2
fi
base_url="$1"
cases_dir="$2"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"
python="${PYTHON:-python3}"

# The virtualenv lives in a cache named after the requirements and the interpreter, so a change
# to either builds a new one.
key="$({ cat "${here}/requirements.txt"; "${python}" --version; } | sha256sum | cut -c1-16)"
venv="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/interop-python-${key}"
if [ ! -f "${venv}/.installed" ]; then
    rm -rf "${venv}"
    "${python}" -m venv "${venv}"
    "${venv}/bin/pip" install --disable-pip-version-check --quiet \
        --require-hashes --only-binary=:all: -r "${here}/requirements.txt"
    touch "${venv}/.installed"
fi

gen="$(mktemp -d)"
trap 'rm -rf "${gen}"' EXIT INT TERM
"${venv}/bin/python" -m grpc_tools.protoc -I "${repo}/examples/proto" \
    --python_out="${gen}" --grpc_python_out="${gen}" \
    "${repo}/examples/proto/coverage/v1/coverage.proto" \
    "${repo}/examples/proto/interop/v1/interop.proto"

"${venv}/bin/python" -I "${here}/client.py" "${gen}" "${base_url}" "${cases_dir}"
