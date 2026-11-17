#!/bin/sh
# The full-stack benchmark (design §8 step 28, decision 44): whole servers on real sockets, over
# TLS 1.3 and h2, under one load generator. Each server answers OTLP's TraceService/Export over
# gRPC: connect-zig's OTLP sink (tools/otlp_sink) and OpenTelemetry's Collector, with its OTLP
# receiver and its nop exporter. h2load sends each the same requests: one export of 16 spans and
# one of 512, which tools/fullstack/otlp_request.py writes and buf encodes with Go's runtime.
#
#   tools/fullstack_check.sh > report.md
#
# Each server runs alone on one core, the Collector with GOMAXPROCS=1, and h2load on two other
# cores, as colibri's judge places them (colibri decision 33). Each round starts each server again,
# in turns, and the report gives the median of the rounds. Each round first sends one export
# through buf curl, which must answer with OTLP's full success. After each round, the server's own
# count of the spans it took must equal the spans sent, with none refused, or the check fails.
# The times report and never gate.
#
# It runs on Linux, where /proc gives a process's CPU time and peak memory. It needs h2load
# (nghttp2-client), buf, python3 and curl; H2LOAD and BUF name them. It downloads the Collector,
# pinned by SHA-256, into a cache, unless OTELCOL names one, and builds the sink with -Drelease,
# unless OTLP_SINK names one.
set -eu
cd "$(dirname "$0")/.."
collector_version="0.165.0"
# The SHA-256 of each archive of the Collector's core distribution, from the release's files.
case "$(uname -m)" in
    x86_64)
        collector_arch=linux_amd64
        collector_sha256=78570dd4bd6570bc41eb327869ef913bbf91b87dd8170ebebbf43bec71f6370d
        ;;
    aarch64)
        collector_arch=linux_arm64
        collector_sha256=e59c320b90885610e346f3f82d2ceca55c5c30ede1549fd14cce577d175901cd
        ;;
    *)
        echo "fullstack: no Collector archive for $(uname -s) $(uname -m); run it on Linux" >&2
        exit 2
        ;;
esac
h2load="${H2LOAD:-h2load}"
buf="${BUF:-buf}"
# The requests of each round for each export, after warm requests that are never counted.
spans_list="16 512"
rounds=3
requests_of() { case "$1" in 16) echo 40000 ;; *) echo 4000 ;; esac; }
warm_divisor=10
# 16 connections of 4 streams each: 64 calls in flight, which the sink's router holds at once.
connections=16
streams=4
# TLS 1.3's one suite every implementation must have (RFC 8446 §9.1), so each server runs the same.
tls_suite=TLS_AES_128_GCM_SHA256
ca=examples/harness/tls/ca.pem
export_path=/opentelemetry.proto.collector.trace.v1.TraceService/Export
sink_port=14317
collector_port=14318
metrics_port=18888
# The server on core 1 and h2load on cores 2 and 3, where the machine has 4.
cores_needed=4
if [ "$(nproc)" -ge "${cores_needed}" ]; then
    server_pin="taskset -c 1" load_pin="taskset -c 2,3" load_threads=2
    placement="each server on core 1, h2load on cores 2 and 3"
else
    server_pin="" load_pin="" load_threads=1
    placement="no core pinned: the machine has fewer than ${cores_needed}"
fi

otelcol="${OTELCOL:-}"
if [ -z "${otelcol}" ]; then
    cache="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig"
    cache="${cache}/otelcol-${collector_version}-${collector_arch}"
    otelcol="${cache}/otelcol"
    if [ ! -x "${otelcol}" ]; then
        mkdir -p "${cache}"
        archive="${cache}/otelcol.tar.gz"
        curl -sSfL -o "${archive}" \
            "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${collector_version}/otelcol_${collector_version}_${collector_arch}.tar.gz"
        echo "${collector_sha256}  ${archive}" | sha256sum -c - >&2
        tar -xzf "${archive}" -C "${cache}" otelcol
        rm -f "${archive}"
    fi
fi
sink="${OTLP_SINK:-}"
if [ -z "${sink}" ]; then
    zig build otlp-sink -Drelease >&2
    sink=zig-out/bin/otlp-sink
fi

work="$(mktemp -d)"
server_pid=""
stop() {
    if [ -n "${server_pid}" ]; then
        kill "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
    fi
    server_pid=""
}
trap 'stop; rm -rf "${work}"' EXIT

# Each export as h2load sends it: the encoding, in gRPC's Length-Prefixed-Message.
for spans in ${spans_list}; do
    python3 tools/fullstack/otlp_request.py "${buf}" "${spans}" "${work}/export-${spans}.grpc"
done

cat >"${work}/otelcol.yaml" <<YAML
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:${collector_port}
        tls:
          cert_file: $(pwd)/examples/harness/tls/chain.pem
          key_file: $(pwd)/examples/harness/tls/key.pem
exporters:
  nop:
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [nop]
  telemetry:
    logs:
      level: warn
    metrics:
      readers:
        - pull:
            exporter:
              prometheus:
                host: 127.0.0.1
                port: ${metrics_port}
YAML

port_of() { case "$1" in connect-zig) echo "${sink_port}" ;; *) echo "${collector_port}" ;; esac; }

# Starts a server on its core, and waits until it answers over TLS.
start() {
    case "$1" in
        connect-zig) ${server_pin} "${sink}" "${sink_port}" >"${work}/server.log" 2>&1 & ;;
        collector) GOMAXPROCS=1 ${server_pin} "${otelcol}" --config "${work}/otelcol.yaml" \
            >"${work}/server.log" 2>&1 & ;;
    esac
    server_pid=$!
    for _ in $(seq 1 100); do
        curl -s -o /dev/null --cacert "${ca}" "https://127.0.0.1:$(port_of "$1")/" && return 0
        sleep 0.1
    done
    echo "fullstack: the $1 server did not start" >&2
    cat "${work}/server.log" >&2
    return 1
}

# h2load's calls of one export, with its report on standard output.
load() {
    ${load_pin} "${h2load}" -n "$3" -c "${connections}" -m "${streams}" -t "${load_threads}" \
        --tls13-ciphers="${tls_suite}" -d "${work}/export-$2.grpc" \
        -H 'content-type: application/grpc' -H 'te: trailers' ${4:+"--log-file=$4"} \
        "https://127.0.0.1:$(port_of "$1")${export_path}"
}

# The spans a server says it took and refused.
counted() {
    case "$1" in
        connect-zig) curl -sS --cacert "${ca}" "https://127.0.0.1:${sink_port}/sink/count" |
            awk '{ print $4, 0 }' ;;
        collector) curl -sS "http://127.0.0.1:${metrics_port}/metrics" | awk '
            /^otelcol_receiver_accepted_spans/ { taken += $NF }
            /^otelcol_receiver_refused_spans/ { refused += $NF }
            END { printf "%d %d\n", taken, refused }' ;;
    esac
}

# One export through buf curl, which must answer with OTLP's full success: no span refused and
# no message (OTLP specification, "Full Success" and "Partial Success"). The sink leaves
# partial_success unset, and the Collector sets it empty. gRPC states a call's status in its
# trailers, which h2load does not read, so this call checks what h2load cannot.
probe() {
    answer="$("${buf}" curl --schema examples/otlp/proto --protocol grpc --cacert "${ca}" \
        -d @"${work}/export-$2.grpc.json" "https://127.0.0.1:$(port_of "$1")${export_path}" \
        2>"${work}/probe.log")" || true
    case "$(printf '%s' "${answer}" | tr -d ' \n')" in
        '{}' | '{"partialSuccess":{}}') return 0 ;;
    esac
    echo "fullstack: $1, $2 spans: the export answered '${answer}'" >&2
    cat "${work}/probe.log" >&2
    return 1
}

cpu_ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat"; }
peak_kb() { awk '/^VmHWM:/ { print $2 }' "/proc/$1/status"; }

# One round of a server and an export: a line of the results, or a failure. The caller tests its
# status, so `set -e` stops nothing here, and each failure returns by name.
measure() {
    server="$1" spans="$2" requests="$(requests_of "$2")"
    warm=$((requests / warm_divisor))
    start "${server}" || { stop; return 1; }
    probe "${server}" "${spans}" || { stop; return 1; }
    load "${server}" "${spans}" "${warm}" >"${work}/warm.txt"
    # h2load appends to its log, so each round starts with none.
    rm -f "${work}/calls.log"
    before="$(cpu_ticks "${server_pid}")"
    load "${server}" "${spans}" "${requests}" "${work}/calls.log" >"${work}/load.txt"
    after="$(cpu_ticks "${server_pid}")"
    peak="$(peak_kb "${server_pid}")"
    set -- $(counted "${server}")
    stop
    # The probe's export, the warm ones and the measured ones.
    expected=$(((1 + warm + requests) * spans))
    succeeded="$(awk '/^requests:/ { print $8 }' "${work}/load.txt")"
    if [ "$1" -ne "${expected}" ] || [ "$2" -ne 0 ] || [ "${succeeded}" -ne "${requests}" ]; then
        echo "fullstack: ${server}, ${spans} spans: took $1 spans and refused $2, of ${expected};" \
            "h2load: ${succeeded} of ${requests} succeeded" >&2
        cat "${work}/load.txt" >&2
        return 1
    fi
    # h2load's log holds a line for each call: its start, its status, and its microseconds.
    latency="$(cut -f3 "${work}/calls.log" | sort -n | awk '
        { at[NR] = $1 }
        END { print at[rank(50)], at[rank(99)] }
        # The nearest rank: the smallest value at or above p percent of the calls.
        function rank(p, place) {
            place = int(NR * p / 100)
            return place < NR * p / 100 ? place + 1 : place
        }')"
    rate="$(awk '/^finished in/ { print $4 }' "${work}/load.txt")"
    echo "${spans} ${server} ${rate} ${latency} $((after - before)) ${requests} ${peak}"
}

status=0
: >"${work}/results"
for round in $(seq 1 "${rounds}"); do
    for spans in ${spans_list}; do
        for server in connect-zig collector; do
            echo "fullstack: round ${round}, ${server}, ${spans} spans" >&2
            measure "${server}" "${spans}" >>"${work}/results" || status=1
        done
    done
done
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
loader="$("${h2load}" --version | head -1)"
collector="$("${otelcol}" --version)"
python3 tools/fullstack/report.py "${work}" "$(getconf CLK_TCK)" "${loader}" "${collector}" \
    "${commit}" "${placement}" "${rounds}" "${connections}" "${streams}" "${tls_suite}"
exit "${status}"
