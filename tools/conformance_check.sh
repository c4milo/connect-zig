#!/bin/sh
# Runs connectrpc's conformance suite against both halves (decision 26). In server mode the runner
# calls the conformance server with every case config.yaml declares, in Connect, gRPC and gRPC-Web,
# over h11 and h2. In client mode it runs its reference server and hands the conformance client
# every case client_config.yaml declares, over h11, h2 and h3, in cleartext and over TLS. The cases
# of conformance/known_failing.txt and conformance/client_known_failing.txt fail on purpose, and
# those of conformance/client_known_flaky.txt may fail, each for the reason its file gives.
#
# It downloads the runner, pinned by SHA-256, into a cache, unless CONNECTCONFORMANCE names one.
set -eu
cd "$(dirname "$0")/.."
version="1.0.4"
sha256="b0b69570a6fc0e0dc94820f209ba47ef26a2dd3e98ed3350ce7fadd00bb51053"
runner="${CONNECTCONFORMANCE:-}"
if [ -z "${runner}" ]; then
    cache="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/conformance-${version}"
    runner="${cache}/connectconformance"
    if [ ! -x "${runner}" ]; then
        mkdir -p "${cache}"
        archive="${cache}/runner.tgz"
        curl -sSfL -o "${archive}" \
            "https://github.com/connectrpc/conformance/releases/download/v${version}/connectconformance-v${version}-Linux-x86_64.tar.gz"
        echo "${sha256}  ${archive}" | sha256sum -c -
        tar -xzf "${archive}" -C "${cache}" connectconformance
        rm -f "${archive}"
    fi
fi
zig build conformance-server conformance-client
server_log="$(mktemp)"
client_log="$(mktemp)"
trap 'rm -f "${server_log}" "${client_log}"' EXIT
status=0
"${runner}" --mode server --conf conformance/config.yaml \
    --known-failing @conformance/known_failing.txt -- zig-out/bin/conformance-server >"${server_log}" 2>&1 || status=$?
cat "${server_log}"
"${runner}" --mode client --conf conformance/client_config.yaml \
    --known-failing @conformance/client_known_failing.txt --known-flaky @conformance/client_known_flaky.txt \
    -- zig-out/bin/conformance-client >"${client_log}" 2>&1 || status=$?
cat "${client_log}"
# Writes a half's totals and each of its failures to the report.
report() {
    echo "## Conformance: connectrpc's runner v${version} against the $1"
    echo
    grep -e '^Total cases' -e 'passed,' -e '^(Another' "$2" | sed 's/^/- /'
    grep '^FAILED: ' "$2" | sed 's/^/- /' || true
    echo
}
# With CONFORMANCE_REPORT naming a file, the runner's totals and each failure go there too.
if [ -n "${CONFORMANCE_REPORT:-}" ]; then
    {
        report server "${server_log}"
        report client "${client_log}"
    } >>"${CONFORMANCE_REPORT}"
fi
exit "${status}"
