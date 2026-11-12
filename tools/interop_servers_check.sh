#!/bin/sh
# Runs connect-zig's client against servers written in other languages: Go's connect-go and
# grpc-go, TypeScript's connect-node, Python's grpcio, and Rust's connect-rust (interop/README.md,
# "The server side"). It is the mirror of tools/interop_languages_check.sh. The client,
# examples/interop_client.zig, calls interop.v1.InteropService in every protocol the server
# speaks, with every case of examples/testdata/coverage, the cases that hold every protobuf type.
#
#   tools/interop_servers_check.sh [server...]
#
# With no server named, it runs all five. It needs buf, or BUF naming it, and each server's
# toolchain: go, node with npm, python3 with venv, and cargo. With INTEROP_REPORT naming a file,
# it appends a Markdown table of the results there, and under GitHub Actions it marks each
# failure as an error annotation.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
export BUF="${buf}"
servers="${*:-go grpc-go typescript python connect-rust}"
report="${INTEROP_REPORT:-/dev/null}"
# Each server may take this long to print its port, toolchain installs on a cold cache included,
# and the client this long to run every scenario.
server_seconds=1800
client_seconds=600
zig build interop-client -Drelease
work="$(mktemp -d)"
server=""
trap 'stop_server; rm -rf "${work}"' EXIT

# Stops the server and waits until it ended. `wait` answers the status of the signal that
# stopped it, which must not end this script (`set -e`).
stop_server() {
    [ -n "${server}" ] || return 0
    kill "${server}" 2>/dev/null || true
    wait "${server}" 2>/dev/null || true
    server=""
}

# The cases in binary, which every runtime reads, and the schema for the servers that compile it.
mkdir -p "${work}/cases"
for case in examples/testdata/coverage/*.json; do
    "${buf}" convert examples/proto --type coverage.v1.Everything --from "${case}#format=json" \
        --to "${work}/cases/$(basename "${case}" .json).binpb#format=binpb"
done
"${buf}" build examples/proto --as-file-descriptor-set -o "${work}/descriptors.binpb"
tls="$(pwd)/examples/testdata/tls"

# What each server is: its directory under interop/, the client's runs it speaks, and each
# scenario its library cannot express, which the client leaves out (interop/README.md).
every="connect-proto connect-json connect-h1 grpc grpc-web grpc-web-h1"
h1_chat="--leave-out=connect-h1/chat --leave-out=grpc-web-h1/chat"
directory_of() {
    case "$1" in
        go | grpc-go) echo go ;;
        *) echo "$1" ;;
    esac
}
protocols_of() {
    case "$1" in
        grpc-go | python) echo grpc ;;
        *) echo "${every}" ;;
    esac
}
# connect-go and connect-node answer a bidirectional stream over HTTP/1.1 with 505.
left_out_of() {
    case "$1" in
        go | typescript) echo "${h1_chat}" ;;
        *) echo "" ;;
    esac
}

# Starts a server and sets `port`, which stays empty when the server printed none in time. A
# caller runs it in this shell, never in a command substitution: a subshell keeps `server` to
# itself, and stop_server then stops nothing.
start_server() {
    port=""
    "interop/$(directory_of "$1")/serve.sh" "$1" 0 "${tls}/chain.pem" "${tls}/key.pem" "${work}/descriptors.binpb" \
        >"${work}/$1.server.log" 2>&1 &
    server=$!
    for _ in $(seq 1 $((server_seconds * 5))); do
        port="$(sed -n 's/^listening on port \([0-9]*\)$/\1/p' "${work}/$1.server.log")"
        [ -n "${port}" ] && return 0
        kill -0 "${server}" 2>/dev/null || return 0
        sleep 0.2
    done
}

# One row for each server and protocol: the scenarios that passed, and each one that failed.
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
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=interop server $1::$2"
    return 0
}

{
    echo "## Interop: connect-zig's client against servers in other languages"
    echo
    echo "| Server | Protocol | Passed | Failed |"
    echo "| --- | --- | ---: | --- |"
} >>"${report}"
failed=0
for name in ${servers}; do
    echo "== ${name}"
    start_server "${name}"
    # The script holds the process it started, or it cannot stop it.
    [ -n "${server}" ] || { echo "the script lost the process of ${name}" >&2; exit 1; }
    status=0
    if [ -z "${port}" ]; then
        cat "${work}/${name}.server.log"
        echo "the server printed no port" >"${work}/${name}.out"
        status=1
    else
        # shellcheck disable=SC2046 # each option and protocol is one word
        timeout "${client_seconds}" zig-out/bin/interop-client $(left_out_of "${name}") "${name}" \
            "https://127.0.0.1:${port}" "${work}/cases" "${tls}/ca.pem" $(protocols_of "${name}") \
            >"${work}/${name}.out" 2>&1 || status=$?
    fi
    stop_server
    cat "${work}/${name}.out"
    grep -e '^ok: ' -e '^FAIL: ' "${work}/${name}.out" >"${work}/${name}.lines" || true
    if [ "${status}" -ne 0 ] || grep -q '^FAIL: ' "${work}/${name}.lines" || [ ! -s "${work}/${name}.lines" ]; then
        failed=$((failed + 1))
    fi
    summarize "${name}" "${status}"
done

[ "${failed}" -eq 0 ] || { echo "${failed} interop server(s) failed" >&2; exit 1; }
echo "every interop server answered as expected"
