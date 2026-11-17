#!/bin/sh
# The full-stack benchmark (design §8 steps 28 and 29, decision 44): whole servers on real sockets,
# over TLS 1.3 and h2. Each server answers OTLP's TraceService/Export over gRPC: connect-zig's OTLP
# sink (tools/otlp_sink) and OpenTelemetry's Collector, with its OTLP receiver and its nop
# exporter. Each server runs alone on one core, the Collector with GOMAXPROCS=1, and the load runs
# on two other cores, as colibri's judge places them (colibri decision 33).
#
#   tools/fullstack_check.sh [peak] [production] > report.md
#
# It runs two parts, both unless the command line names one:
#
# - peak (tools/fullstack/peak.sh): h2load sends exports of 16 spans, then of 512, on 16
#   connections of 4 streams, as fast as each server answers.
# - production (tools/fullstack/production.sh): the traffic of one gateway core for a fleet of
#   33,000 servers. oha sends a mix of gzip exports on 516 connections, at rates that climb until
#   p99 passes 100 ms or a call is refused.
#
# Each part checks every answer. One export through buf curl must answer with OTLP's full success,
# and each server's own count of spans must equal the spans it was sent, with none refused. The
# times report and never gate.
#
# It runs on Linux, where /proc gives a process's CPU time and peak memory. It needs h2load
# (nghttp2-client), buf, python3 and curl; H2LOAD and BUF name them. It downloads the Collector
# and oha, each pinned by SHA-256, into a cache, unless OTELCOL and OHA name them. It builds the
# sink with -Drelease, unless OTLP_SINK names one.
set -eu
cd "$(dirname "$0")/.."
# The reports import tools/fullstack/machine.py, and Python leaves no cache of it in the tree.
export PYTHONDONTWRITEBYTECODE=1
parts="${*:-peak production}"
collector_version="0.165.0"
oha_version="v1.16.0"
# The SHA-256 of each download: the Collector's core distribution, from its release's .sha256
# files, and oha's binary, which GitHub's digest of the release asset confirms.
case "$(uname -m)" in
    x86_64)
        arch=amd64
        collector_sha256=78570dd4bd6570bc41eb327869ef913bbf91b87dd8170ebebbf43bec71f6370d
        oha_sha256=620bb9e16fb53eabc9a3fc45f88bdb41fefa3fee5c05e75892011ce320391716
        ;;
    aarch64)
        arch=arm64
        collector_sha256=e59c320b90885610e346f3f82d2ceca55c5c30ede1549fd14cce577d175901cd
        oha_sha256=99a790eb8c3e0feaca974bd6b32f0f8d4426a0c5b289f39e833e5b2c7529cd39
        ;;
    *)
        echo "fullstack: no Collector or oha for $(uname -s) $(uname -m); run it on Linux" >&2
        exit 2
        ;;
esac
h2load="${H2LOAD:-h2load}"
buf="${BUF:-buf}"
# TLS 1.3's one suite every implementation must have (RFC 8446 §9.1), so each server runs the same.
tls_suite=TLS_AES_128_GCM_SHA256
ca=examples/harness/tls/ca.pem
export_path=/opentelemetry.proto.collector.trace.v1.TraceService/Export
sink_port=14317
collector_port=14318
metrics_port=18888
# The server on core 1 and the load on cores 2 and 3, where the machine has 4.
cores_needed=4
if [ "$(nproc)" -ge "${cores_needed}" ]; then
    server_pin="taskset -c 1" load_pin="taskset -c 2,3" load_threads=2
    placement="each server on core 1, the load on cores 2 and 3"
else
    server_pin="" load_pin="" load_threads=1
    placement="no core pinned: the machine has fewer than ${cores_needed}"
fi

# Downloads a release into the cache once, checked by its SHA-256, and prints the program's path.
# An archive gives the one file that the fourth argument names.
fetch() {
    dir="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/$1"
    if [ ! -x "${dir}/program" ]; then
        mkdir -p "${dir}"
        curl -sSfL -o "${dir}/download" "$2"
        echo "$3  ${dir}/download" | sha256sum -c - >&2
        if [ -n "${4:-}" ]; then
            tar -xzf "${dir}/download" -C "${dir}" "$4"
            mv "${dir}/$4" "${dir}/program"
            rm -f "${dir}/download"
        else
            mv "${dir}/download" "${dir}/program"
        fi
        chmod 0755 "${dir}/program"
    fi
    echo "${dir}/program"
}
releases=https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download
otelcol="${OTELCOL:-$(fetch "otelcol-${collector_version}-${arch}" \
    "${releases}/v${collector_version}/otelcol_${collector_version}_linux_${arch}.tar.gz" \
    "${collector_sha256}" otelcol)}"
oha="${OHA:-$(fetch "oha-${oha_version}-${arch}" \
    "https://github.com/hatoo/oha/releases/download/${oha_version}/oha-linux-${arch}" \
    "${oha_sha256}")}"
sink="${OTLP_SINK:-}"
if [ -z "${sink}" ]; then
    zig build otlp-sink -Drelease >&2
    sink=zig-out/bin/otlp-sink
fi
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
collector="$("${otelcol}" --version)"

work="$(mktemp -d)"
server_pid=""
trap 'stop; rm -rf "${work}"' EXIT
. tools/fullstack/servers.sh

status=0
for part in ${parts}; do
    case "${part}" in
        peak) . tools/fullstack/peak.sh ;;
        production) . tools/fullstack/production.sh ;;
        *) echo "fullstack: no part named ${part}" >&2; exit 2 ;;
    esac
done
exit "${status}"
