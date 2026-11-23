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
#   tools/fullstack_check.sh [peak] [production] [production-cleartext] [compression]
#                            [compression-cleartext] > report.md
#
# It runs the parts the command line names, or peak and production when it names none:
#
# - peak (tools/fullstack/peak.sh): over TLS 1.3, h2load sends exports of 16 spans, then of 512,
#   on 16 connections of 4 streams, as fast as each server answers.
# - production (tools/fullstack/production.sh): the traffic of one gateway core for a fleet of
#   33,000 servers. tools/fullstack/load sends a mix of gzip exports on 516 connections, which stay
#   open across the climb, at rates that climb until p99 passes 100 ms or a call is refused, over
#   TLS to connect-zig, the Collector, Vector, connect-go and connect-rust, in three rounds of each.
# - production-cleartext: the same climbs in cleartext h2, to connect-zig, the Collector and
#   Rotel, whose receiver has no TLS.
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
# downloads the Collector, Vector and Rotel, each pinned by SHA-256, into a cache, unless OTELCOL,
# VECTOR and ROTEL name them. It builds the three sinks with -Drelease, unless OTLP_SINK,
# OTLP_SINK_VALIDATE and OTLP_SINK_COMPRESSION name them, the two receivers, unless CONNECT_GO and
# CONNECT_RUST name them, and the climb's load, unless FULLSTACK_LOAD names it. The compression parts run
# `otlp-sink-compression`, which holds more calls at once (tools/otlp_sink/constants.zig).
set -eu
cd "$(dirname "$0")/.."
# The reports import tools/fullstack/machine.py, and Python leaves no cache of it in the tree.
export PYTHONDONTWRITEBYTECODE=1
parts="${*:-peak production}"
collector_version="0.165.0"
vector_version="0.62.0"
rotel_version="v0.2.7"
# The SHA-256 of each download: the Collector's core distribution, from its release's .sha256
# files, and Vector's and Rotel's builds, as GitHub's digest of each release asset states.
case "$(uname -m)" in
    x86_64)
        arch=amd64
        collector_sha256=78570dd4bd6570bc41eb327869ef913bbf91b87dd8170ebebbf43bec71f6370d
        vector_sha256=e9d9cb3ee12288544c813453d0548524ab2bcc8f7e81b601f5e9d378fa6ac2f6
        rotel_sha256=8f4530006034775e9089a86c1e4aca1c26f7b8416daf394334cff37e84d31eee
        ;;
    aarch64)
        arch=arm64
        collector_sha256=e59c320b90885610e346f3f82d2ceca55c5c30ede1549fd14cce577d175901cd
        vector_sha256=99532dce9a1e36a6f604d806c325a52d45f2b738e4c04ccb43bc3db96078c581
        rotel_sha256=9e68282b6a2f667f56f793c055d496d258a25fbed4cb2c013a56dcf4fcd9e74e
        ;;
    *)
        echo "fullstack: no Collector for $(uname -s) $(uname -m); run it on Linux" >&2
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
# The server and the load on separate physical cores, where the machine has 4 CPUs, from Linux's
# CPU topology (tools/fullstack/placement.py).
cpus_needed=4
read -r server_cpu load_cpus core_threads <<PLACEMENT
$(python3 tools/fullstack/placement.py)
PLACEMENT
if [ "${server_cpu}" != - ]; then
    server_pin="taskset -c ${server_cpu}" load_pin="taskset -c ${load_cpus}" load_cores="${load_cpus}" load_threads=2
    if [ "${core_threads}" -gt 1 ]; then
        placement="each server on CPU ${server_cpu}, which shares its core with CPU 0, where the scripts run; the load on CPUs ${load_cpus}, the ${core_threads} threads of another core"
    else
        placement="each server on core ${server_cpu}, the load on cores ${load_cpus}"
    fi
else
    server_pin="" load_pin="" load_cores="" load_threads=1
    placement="no core pinned: the machine has fewer than ${cpus_needed} CPUs"
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
# is built for this machine's CPU, as connect-zig's sink is: Go at the highest level of the CPU
# that Go names, and Rust with LTO and `target-cpu=native` (tools/host_cpu.sh). Each build lives in
# the cache, outside the repository and named for the CPU, unless CONNECT_GO and CONNECT_RUST name
# one.
. tools/host_cpu.sh
cache="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig"
go_build="$(go_level)"
connect_go="${CONNECT_GO:-}"
if [ -z "${connect_go}" ]; then
    bin="${cache}/fullstack-connect-go-$(sha256sum tools/fullstack/connect-go/go.sum | cut -c1-12)-$(host_features)"
    mkdir -p "${bin}"
    (
        cd tools/fullstack/connect-go
        export GOFLAGS=-mod=readonly
        go build -o "${bin}/protoc-gen-go" google.golang.org/protobuf/cmd/protoc-gen-go
        go build -o "${bin}/protoc-gen-connect-go" connectrpc.com/connect/cmd/protoc-gen-connect-go
        PATH="${bin}:${PATH}" "${buf}" generate
        env ${go_build} go build -o "${bin}/connect-go" .
    ) >&2
    connect_go="${bin}/connect-go"
fi
connect_rust="${CONNECT_RUST:-}"
if [ -z "${connect_rust}" ]; then
    target="${cache}/fullstack-connect-rust-target-$(host_features)"
    mkdir -p "${target}"
    # The descriptors move only when the schema does, so Cargo builds the crate again only then.
    # tools/fullstack/validate's copy of the schema: the same messages, whose spans carry OTLP's
    # rules, which the receiver checks with `validate`.
    "${buf}" build . --path tools/fullstack/validate/proto/opentelemetry --as-file-descriptor-set \
        -o "${target}/otlp.new.binpb"
    cmp -s "${target}/otlp.new.binpb" "${target}/otlp.binpb" ||
        mv "${target}/otlp.new.binpb" "${target}/otlp.binpb"
    RUSTFLAGS="${rust_native}" OTLP_DESCRIPTORS="${target}/otlp.binpb" CARGO_TARGET_DIR="${target}" \
        cargo build --quiet --locked --release --manifest-path tools/fullstack/connect-rust/Cargo.toml >&2
    connect_rust="${target}/release/fullstack-connect-rust"
fi
# The climb's load (tools/fullstack/load), in release with the crates its Cargo.lock pins, built
# for this machine's CPU as the receivers are.
fullstack_load="${FULLSTACK_LOAD:-}"
if [ -z "${fullstack_load}" ]; then
    target="${cache}/fullstack-load-target-$(host_features)"
    RUSTFLAGS="${rust_native}" CARGO_TARGET_DIR="${target}" \
        cargo build --quiet --locked --release --manifest-path tools/fullstack/load/Cargo.toml >&2
    fullstack_load="${target}/release/fullstack-load"
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
# The sink built for the architecture's baseline CPU, which the peak part runs beside the sink
# built for this machine's: what the build for the host's CPU gives connect-zig. The servers it is
# compared with ship builds for the baseline CPU.
sink_generic="${OTLP_SINK_GENERIC:-}"
if [ -z "${sink_generic}" ]; then
    zig build otlp-sink -Drelease -Dcpu=baseline --prefix zig-out/generic >&2
    sink_generic=zig-out/generic/bin/otlp-sink
fi
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
collector="$("${otelcol}" --version)"
vector_text="$("${vector}" --version | cut -d' ' -f1-2)"
rotel_text="$("${rotel}" --version)"
# Each receiver's version, and how it was built for this CPU when this script built it.
connect_go_text="connect-go $(awk '$1 == "connectrpc.com/connect" { print $2 }' tools/fullstack/connect-go/go.mod)"
[ -n "${CONNECT_GO:-}" ] || connect_go_text="${connect_go_text} built with ${go_build:-Go's defaults}"
connect_rust_text="connect-rust $(awk '$0 == "name = \"connectrpc\"" { getline; gsub(/"/, "", $3); print "v" $3 }' tools/fullstack/connect-rust/Cargo.lock)"
[ -n "${CONNECT_RUST:-}" ] || connect_rust_text="${connect_rust_text} built with LTO and target-cpu=native"
# A crate's version in the load's Cargo.lock.
load_crate() { awk -v name="name = \"$1\"" '$0 == name { getline; gsub(/"/, "", $3); print $3 }' tools/fullstack/load/Cargo.lock; }
load_text="tools/fullstack/load, on h2 $(load_crate h2), tokio $(load_crate tokio) and rustls $(load_crate rustls) with ring"
[ -n "${FULLSTACK_LOAD:-}" ] || load_text="${load_text}, built with LTO and target-cpu=native"

work="$(mktemp -d)"
server_pid=""
counter_pid=""
load_pid=""
trap 'stop; [ -z "${load_pid}" ] || kill "${load_pid}" 2>/dev/null; rm -rf "${work}"' EXIT
. tools/fullstack/servers.sh
. tools/fullstack/peak.sh
. tools/fullstack/production.sh
. tools/fullstack/compression.sh

status=0
for part in ${parts}; do
    case "${part}" in
        peak) peak_part ;;
        production) production_part tls ;;
        production-cleartext) production_part cleartext ;;
        compression) compression_part tls ;;
        compression-cleartext) compression_part cleartext ;;
        *) echo "fullstack: no part named ${part}" >&2; exit 2 ;;
    esac
done
exit "${status}"
