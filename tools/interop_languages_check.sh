#!/bin/sh
# Runs clients written in other languages against connect-zig's server: Go's connect-go and
# grpc-go, TypeScript's connect-es, Python's grpcio and Rust's tonic (interop/README.md). Each
# calls interop.v1.InteropService in every protocol, codec and compression its library speaks,
# with every case of examples/testdata/coverage, the cases that hold every protobuf type.
#
#   tools/interop_languages_check.sh [client...]
#
# With no client named, it runs all four. It needs buf, or BUF naming it, and each client's
# toolchain: go, node with npm, python3 with venv, and cargo. With INTEROP_REPORT naming a file,
# it appends a Markdown table of the results there, and under GitHub Actions it marks each
# failure as an error annotation.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
export BUF="${buf}"
clients="${*:-go typescript python rust}"
report="${INTEROP_REPORT:-/dev/null}"
# Each client runs at most this many seconds, toolchain installs on a cold cache included.
client_seconds=1800
zig build
work="$(mktemp -d)"
trap 'kill "${server}" 2>/dev/null || true; rm -rf "${work}"' EXIT
zig-out/bin/eliza-server 0 >"${work}/server.log" 2>&1 &
server=$!
port=""
for _ in $(seq 1 50); do
    port="$(sed -n 's/^listening on port \([0-9]*\)$/\1/p' "${work}/server.log")"
    [ -n "${port}" ] && break
    sleep 0.1
done
[ -n "${port}" ] || { echo "the server printed no port" >&2; exit 1; }
base="http://127.0.0.1:${port}"
# The cases in binary, which every runtime reads, and the schema for the clients that compile it.
mkdir -p "${work}/cases"
for case in examples/testdata/coverage/*.json; do
    "${buf}" convert examples/proto --type coverage.v1.Everything --from "${case}#format=json" \
        --to "${work}/cases/$(basename "${case}" .json).binpb#format=binpb"
done
"${buf}" build examples/proto --as-file-descriptor-set -o "${work}/descriptors.binpb"

# One row for each client and protocol: the scenarios that passed, and each one that failed.
summarize() {
    lines="${work}/$1.lines"
    if [ ! -s "${lines}" ]; then
        echo "| $1 | | 0 | the client ran no scenario (exit $2) |" >>"${report}"
        annotate "$1" "the client ran no scenario (exit $2)"
        return
    fi
    for protocol in $(awk '{ print $3 }' "${lines}" | sort -u); do
        passed="$(grep -c "^ok: $1 ${protocol} " "${lines}" || true)"
        failures="$(grep "^FAIL: $1 ${protocol} " "${lines}" | sed "s/^FAIL: $1 ${protocol} //; s/|/\\\\|/g" | tr '\n' ';' || true)"
        echo "| $1 | ${protocol} | ${passed} | ${failures:-none} |" >>"${report}"
    done
    grep '^FAIL: ' "${lines}" | while IFS= read -r line; do annotate "$1" "${line}"; done
}

annotate() {
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=interop $1::$2"
    return 0
}

{
    echo "## Interop: clients in other languages against connect-zig's server"
    echo
    echo "| Client | Protocol | Passed | Failed |"
    echo "| --- | --- | ---: | --- |"
} >>"${report}"
failed=0
for client in ${clients}; do
    echo "== ${client}"
    status=0
    timeout "${client_seconds}" "interop/${client}/run.sh" "${base}" "${work}/cases" "${work}/descriptors.binpb" \
        >"${work}/${client}.out" 2>&1 || status=$?
    cat "${work}/${client}.out"
    grep -e '^ok: ' -e '^FAIL: ' "${work}/${client}.out" >"${work}/${client}.lines" || true
    if [ "${status}" -ne 0 ] || grep -q '^FAIL: ' "${work}/${client}.lines" || [ ! -s "${work}/${client}.lines" ]; then
        failed=$((failed + 1))
    fi
    summarize "${client}" "${status}"
done

[ "${failed}" -eq 0 ] || { echo "${failed} interop client(s) failed" >&2; exit 1; }
echo "every interop client answered as expected"
