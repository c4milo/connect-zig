#!/bin/sh
# The full-stack benchmark (design §8 steps 28 to 31, decisions 44 and 46): whole servers on real
# sockets, over h2. Each server answers OTLP's TraceService/Export over gRPC and drops what it
# reads: connect-zig's OTLP sink (tools/otlp_sink); OpenTelemetry's Collector, with its OTLP
# receiver and its nop exporter; two servers in Rust, Vector with its blackhole sink, and Rotel
# with its blackhole exporter; and receivers on two other Connect libraries, connect-go and
# connect-rust (tools/fullstack/connect-go and tools/fullstack/connect-rust), which count spans
# as the sink does. The three Connect receivers also run as receivers that validate each export
# with protovalidate against the rules of tools/fullstack/validate: `otlp-sink-validate`, and the
# receivers on connect-go and connect-rust with protovalidate-go and protovalidate-buffa, so the
# report gives what validation costs each. Each server runs alone on one core, the Collector and
# connect-go with
# GOMAXPROCS=1, Vector with one thread, and connect-rust with one tokio worker. The load runs on
# two other cores, as colibri's judge places them (colibri decision 33).
#
#   tools/fullstack_check.sh [peak] [production] [compression] [compression-cleartext] > report.md
#
# It runs the parts the command line names, or peak and production when it names none:
#
# - peak (tools/fullstack/peak.sh): over TLS 1.3, h2load sends exports of 16 spans, then of 512,
#   on 16 connections of 4 streams, as fast as each server answers.
# - production (tools/fullstack/production.sh): the traffic of one gateway core for a fleet of
#   33,000 servers. oha sends a mix of gzip exports on 516 connections, at rates that climb until
#   p99 passes 100 ms or a call is refused: over TLS to connect-zig, the Collector, Vector,
#   connect-go and connect-rust, then in cleartext to connect-zig, the Collector and Rotel, whose
#   receiver has no TLS.
# - compression and compression-cleartext (tools/fullstack/compression.sh): the three Connect
#   receivers under both loads, over TLS 1.3 or in cleartext h2, with exports in no coding and in
#   gzip, zstd and brotli, which `zig build otlp-compress` writes with stdx's encoders.
#
# Each part checks every answer. One export through buf curl must answer with OTLP's full success,
# a receiver that validates must refuse one that breaks a rule, and each server's own count of
# spans must equal the spans it was sent, with none refused. The times report and never gate.
#
# It runs on Linux, where /proc gives a process's CPU time and peak memory. It needs h2load
# (nghttp2-client), buf, python3, curl, go and cargo; H2LOAD and BUF name the first two. It
# downloads the Collector, Vector, Rotel and oha, each pinned by SHA-256, into a cache, unless
# OTELCOL, VECTOR, ROTEL and OHA name them. It builds the three sinks with -Drelease, unless
# OTLP_SINK, OTLP_SINK_VALIDATE and OTLP_SINK_COMPRESSION name them, and the two receivers,
# unless CONNECT_GO and CONNECT_RUST name them. The compression parts run
# `otlp-sink-compression`, which holds more calls at once (tools/otlp_sink/constants.zig).
set -eu
cd "$(dirname "$0")/.."
# The reports import tools/fullstack/machine.py, and Python leaves no cache of it in the tree.
export PYTHONDONTWRITEBYTECODE=1
parts="${*:-peak production}"
collector_version="0.165.0"
oha_version="v1.16.0"
vector_version="0.62.0"
rotel_version="v0.2.7"
# The SHA-256 of each download: the Collector's core distribution, from its release's .sha256
# files, and oha's, Vector's and Rotel's builds, as GitHub's digest of each release asset states.
case "$(uname -m)" in
    x86_64)
        arch=amd64
        collector_sha256=78570dd4bd6570bc41eb327869ef913bbf91b87dd8170ebebbf43bec71f6370d
        oha_sha256=620bb9e16fb53eabc9a3fc45f88bdb41fefa3fee5c05e75892011ce320391716
        vector_sha256=e9d9cb3ee12288544c813453d0548524ab2bcc8f7e81b601f5e9d378fa6ac2f6
        rotel_sha256=8f4530006034775e9089a86c1e4aca1c26f7b8416daf394334cff37e84d31eee
        ;;
    aarch64)
        arch=arm64
        collector_sha256=e59c320b90885610e346f3f82d2ceca55c5c30ede1549fd14cce577d175901cd
        oha_sha256=99a790eb8c3e0feaca974bd6b32f0f8d4426a0c5b289f39e833e5b2c7529cd39
        vector_sha256=99532dce9a1e36a6f604d806c325a52d45f2b738e4c04ccb43bc3db96078c581
        rotel_sha256=9e68282b6a2f667f56f793c055d496d258a25fbed4cb2c013a56dcf4fcd9e74e
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
rotel_port=14319
rotel_http_port=14320
vector_port=14321
vector_http_port=14322
vector_metrics_port=18891
connect_go_port=14323
connect_rust_port=14324
connect_rust_count_port=18892
counter_port=14390
counter_metrics_port=18890
# The server on core 1 and the load on cores 2 and 3, where the machine has 4.
cores_needed=4
if [ "$(nproc)" -ge "${cores_needed}" ]; then
    server_pin="taskset -c 1" load_pin="taskset -c 2,3" load_cores="2,3" load_threads=2
    placement="each server on core 1, the load on cores 2 and 3"
else
    server_pin="" load_pin="" load_cores="" load_threads=1
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
# Rust's name of the machine, which Vector's and Rotel's archives carry.
triple="$(uname -m)-unknown-linux-gnu"
vector="${VECTOR:-$(fetch "vector-${vector_version}-${arch}" \
    "https://github.com/vectordotdev/vector/releases/download/v${vector_version}/vector-${vector_version}-${triple}.tar.gz" \
    "${vector_sha256}" "./vector-${triple}/bin/vector")}"
rotel="${ROTEL:-$(fetch "rotel-${rotel_version}-${arch}" \
    "https://github.com/streamfold/rotel/releases/download/${rotel_version}/rotel_${rotel_version}_${triple}.tar.gz" \
    "${rotel_sha256}" rotel)}"
# The receivers on Connect libraries (decision 46): connect-go, built with the plugins and the
# modules its go.sum pins, and connect-rust, in release, with the crates its Cargo.lock pins. Each
# build lives in the cache, outside the repository, unless CONNECT_GO and CONNECT_RUST name one.
cache="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig"
connect_go="${CONNECT_GO:-}"
if [ -z "${connect_go}" ]; then
    bin="${cache}/fullstack-connect-go-$(sha256sum tools/fullstack/connect-go/go.sum | cut -c1-12)"
    mkdir -p "${bin}"
    (
        cd tools/fullstack/connect-go
        export GOFLAGS=-mod=readonly
        go build -o "${bin}/protoc-gen-go" google.golang.org/protobuf/cmd/protoc-gen-go
        go build -o "${bin}/protoc-gen-connect-go" connectrpc.com/connect/cmd/protoc-gen-connect-go
        PATH="${bin}:${PATH}" "${buf}" generate
        go build -o "${bin}/connect-go" .
    ) >&2
    connect_go="${bin}/connect-go"
fi
connect_rust="${CONNECT_RUST:-}"
if [ -z "${connect_rust}" ]; then
    target="${cache}/fullstack-connect-rust-target"
    mkdir -p "${target}"
    # The descriptors move only when the schema does, so Cargo builds the crate again only then.
    # tools/fullstack/validate's copy of the schema: the same messages, whose spans carry OTLP's
    # rules, which the receiver checks with `validate`.
    "${buf}" build . --path tools/fullstack/validate/proto/opentelemetry --as-file-descriptor-set \
        -o "${target}/otlp.new.binpb"
    cmp -s "${target}/otlp.new.binpb" "${target}/otlp.binpb" ||
        mv "${target}/otlp.new.binpb" "${target}/otlp.binpb"
    OTLP_DESCRIPTORS="${target}/otlp.binpb" CARGO_TARGET_DIR="${target}" cargo build --quiet \
        --locked --release --manifest-path tools/fullstack/connect-rust/Cargo.toml >&2
    connect_rust="${target}/release/fullstack-connect-rust"
fi
sink="${OTLP_SINK:-}"
sink_validate="${OTLP_SINK_VALIDATE:-}"
sink_compression="${OTLP_SINK_COMPRESSION:-}"
compress="${OTLP_COMPRESS:-}"
if [ -z "${sink}" ] || [ -z "${sink_validate}" ] || [ -z "${sink_compression}" ] || [ -z "${compress}" ]; then
    zig build otlp-sink otlp-sink-validate otlp-sink-compression otlp-compress -Drelease >&2
    sink="${sink:-zig-out/bin/otlp-sink}"
    sink_validate="${sink_validate:-zig-out/bin/otlp-sink-validate}"
    sink_compression="${sink_compression:-zig-out/bin/otlp-sink-compression}"
    compress="${compress:-zig-out/bin/otlp-compress}"
fi
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
collector="$("${otelcol}" --version)"
vector_text="$("${vector}" --version | cut -d' ' -f1-2)"
rotel_text="$("${rotel}" --version)"
connect_go_text="connect-go $(awk '$1 == "connectrpc.com/connect" { print $2 }' tools/fullstack/connect-go/go.mod)"
connect_rust_text="connect-rust $(awk '$0 == "name = \"connectrpc\"" { getline; gsub(/"/, "", $3); print "v" $3 }' tools/fullstack/connect-rust/Cargo.lock)"

work="$(mktemp -d)"
server_pid=""
counter_pid=""
trap 'stop; rm -rf "${work}"' EXIT
. tools/fullstack/servers.sh
. tools/fullstack/peak.sh
. tools/fullstack/production.sh
. tools/fullstack/compression.sh

status=0
for part in ${parts}; do
    case "${part}" in
        peak) peak_part ;;
        production) production_part ;;
        compression) compression_part tls ;;
        compression-cleartext) compression_part cleartext ;;
        *) echo "fullstack: no part named ${part}" >&2; exit 2 ;;
    esac
done
exit "${status}"
