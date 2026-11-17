# shellcheck shell=sh
# The servers of tools/fullstack_check.sh (decision 44), which sources this file: how each one
# starts on its core, answers the probe, and counts the spans it took. It reads what the script
# sets: work, sink, otelcol, buf, ca, export_path, server_pin and the ports.

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

stop() {
    if [ -n "${server_pid}" ]; then
        kill "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
    fi
    server_pid=""
}

# One export, the proto3 JSON that the second argument names, through buf curl. It must answer
# with OTLP's full success: no span refused and no message (OTLP specification, "Full Success" and
# "Partial Success"). The sink leaves partial_success unset, and the Collector sets it empty. gRPC
# states a call's status in its trailers, which the load generators do not read, so this call
# checks what they cannot.
probe() {
    answer="$("${buf}" curl --schema examples/otlp/proto --protocol grpc --cacert "${ca}" \
        -d @"$2" "https://127.0.0.1:$(port_of "$1")${export_path}" 2>"${work}/probe.log")" || true
    case "$(printf '%s' "${answer}" | tr -d ' \n')" in
        '{}' | '{"partialSuccess":{}}') return 0 ;;
    esac
    echo "fullstack: $1: the export $2 answered '${answer}'" >&2
    cat "${work}/probe.log" >&2
    return 1
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

# Fails when a server's count differs from the spans it was sent, or it refused one.
check_count() {
    set -- "$1" "$2" $(counted "$1")
    [ "$3" -eq "$2" ] && [ "$4" -eq 0 ] && return 0
    echo "fullstack: $1 took $3 spans and refused $4, of $2 sent" >&2
    return 1
}

cpu_ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat"; }
peak_kb() { awk '/^VmHWM:/ { print $2 }' "/proc/$1/status"; }
