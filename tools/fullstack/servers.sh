# shellcheck shell=sh
# The servers of tools/fullstack_check.sh (decision 44), which sources this file: how each one
# starts on its core, answers the probe, and counts the spans it took. It reads what the script
# sets: work, the programs, buf, ca, export_path, the pins and the ports. `transport` says how
# the next server serves: `tls`, TLS 1.3 with ALPN h2, or `cleartext`, h2 with prior knowledge.
transport=tls
# The seconds a count may take to show the last calls: Vector scrapes its own metrics each
# second, and Rotel sends its internal metrics every 10 seconds.
count_tries=15

for mode in tls cleartext; do
    {
        printf 'receivers:\n  otlp:\n    protocols:\n      grpc:\n'
        printf '        endpoint: 127.0.0.1:%s\n' "${collector_port}"
        [ "${mode}" = cleartext ] ||
            printf '        tls:\n          cert_file: %s\n          key_file: %s\n' \
                "$(pwd)/examples/harness/tls/chain.pem" "$(pwd)/examples/harness/tls/key.pem"
        cat <<YAML
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
    } >"${work}/otelcol-${mode}.yaml"
done

# Rotel's internal metrics reach a second Collector, which shows them to Prometheus: Rotel's
# release build has no metrics endpoint of its own.
cat >"${work}/counter.yaml" <<YAML
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:${counter_port}
exporters:
  prometheus:
    endpoint: 127.0.0.1:${counter_metrics_port}
service:
  pipelines:
    metrics:
      receivers: [otlp]
      exporters: [prometheus]
  telemetry:
    logs:
      level: warn
    metrics:
      level: none
YAML

# Vector's gRPC listener offers no ALPN protocol unless its TLS names one, and a client then
# speaks HTTP/1.1 (RFC 7301 §3.2).
mkdir -p "${work}/vector-data"
cat >"${work}/vector.yaml" <<YAML
data_dir: ${work}/vector-data
sources:
  otlp:
    type: opentelemetry
    grpc:
      address: 127.0.0.1:${vector_port}
      tls:
        enabled: true
        crt_file: $(pwd)/examples/harness/tls/chain.pem
        key_file: $(pwd)/examples/harness/tls/key.pem
        alpn_protocols: [h2]
    http:
      address: 127.0.0.1:${vector_http_port}
  vector_metrics:
    type: internal_metrics
sinks:
  drop:
    type: blackhole
    inputs: [otlp.traces]
    print_interval_secs: 0
  metrics:
    type: prometheus_exporter
    inputs: [vector_metrics]
    address: 127.0.0.1:${vector_metrics_port}
YAML

# An export whose first span breaks one of tools/fullstack/validate's rules: its trace_id holds 3
# octets, where OTLP's holds 16. A validating receiver must refuse it.
cat >"${work}/broken.json" <<'JSON'
{"resourceSpans":[{"scopeSpans":[{"spans":[{"traceId":"AAEC","spanId":"AAECAwQFBgc=","name":"GET /","kind":"SPAN_KIND_SERVER","startTimeUnixNano":"100","endTimeUnixNano":"200"}]}]}]}
JSON

# A receiver that validates each export runs on its twin's port: the servers run one at a time.
port_of() {
    case "$1" in
        connect-zig | connect-zig-validate | connect-zig-generic) echo "${sink_port}" ;;
        collector) echo "${collector_port}" ;;
        vector) echo "${vector_port}" ;;
        connect-go | connect-go-validate) echo "${connect_go_port}" ;;
        connect-rust | connect-rust-validate) echo "${connect_rust_port}" ;;
        rotel) echo "${rotel_port}" ;;
    esac
}

# A server's URL for a path, over the transport.
url_of() {
    scheme=https
    [ "${transport}" = tls ] || scheme=http
    echo "${scheme}://127.0.0.1:$(port_of "$1")$2"
}

# curl's and buf curl's options for the transport: the test CA, or HTTP/2 with prior knowledge.
reach() {
    if [ "${transport}" = tls ]; then echo "--cacert ${ca}"; else echo "--http2-prior-knowledge"; fi
}

# The words after a Connect receiver's key: `validate` for a name that ends in -validate, and
# `cleartext` for the transport.
words_of() {
    case "$1" in
        *-validate) printf 'validate ' ;;
    esac
    [ "${transport}" = tls ] || printf 'cleartext'
}

# Starts a server on its core, and waits until it answers.
start() {
    case "$1" in
        connect-zig | connect-zig-validate | connect-zig-generic)
            mode=""
            [ "${transport}" = tls ] || mode=cleartext
            case "$1" in
                connect-zig) program="${sink}" ;;
                connect-zig-validate) program="${sink_validate}" ;;
                *) program="${sink_generic}" ;;
            esac
            ${server_pin} "${program}" "${sink_port}" ${mode} >"${work}/server.log" 2>&1 & ;;
        collector) GOMAXPROCS=1 ${server_pin} "${otelcol}" \
            --config "${work}/otelcol-${transport}.yaml" >"${work}/server.log" 2>&1 & ;;
        vector) ${server_pin} "${vector}" --threads 1 --quiet --config "${work}/vector.yaml" \
            >"${work}/server.log" 2>&1 & ;;
        # Go's runtime and tokio take as many threads as there are cores, unless told one.
        connect-go | connect-go-validate) GOMAXPROCS=1 ${server_pin} "${connect_go}" \
            "${connect_go_port}" "$(pwd)/examples/harness/tls/chain.pem" \
            "$(pwd)/examples/harness/tls/key.pem" $(words_of "$1") >"${work}/server.log" 2>&1 & ;;
        connect-rust | connect-rust-validate)
            TOKIO_WORKER_THREADS=1 ${server_pin} "${connect_rust}" "${connect_rust_port}" \
                "${connect_rust_count_port}" "$(pwd)/examples/harness/tls/chain.pem" \
                "$(pwd)/examples/harness/tls/key.pem" $(words_of "$1") >"${work}/server.log" 2>&1 & ;;
        rotel)
            ${load_pin} "${otelcol}" --config "${work}/counter.yaml" >"${work}/counter.log" 2>&1 &
            counter_pid=$!
            # Rotel sends its internal metrics only while a metrics exporter is named.
            ROTEL_EXPORTER_STATS_ENDPOINT="http://127.0.0.1:${counter_port}" \
                ${server_pin} "${rotel}" start --otlp-grpc-endpoint "127.0.0.1:${rotel_port}" \
                --otlp-http-endpoint "127.0.0.1:${rotel_http_port}" \
                --exporters traces:blackhole,stats:otlp --exporters-traces traces \
                --exporters-metrics stats --exporters-internal-metrics stats \
                --enable-internal-telemetry >"${work}/server.log" 2>&1 & ;;
    esac
    server_pid=$!
    for _ in $(seq 1 100); do
        curl -s -o /dev/null $(reach) "$(url_of "$1" /)" && return 0
        sleep 0.1
    done
    echo "fullstack: the $1 server did not start" >&2
    cat "${work}/server.log" >&2
    return 1
}

stop() {
    for pid in ${server_pid} ${counter_pid:-}; do
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done
    server_pid=""
    counter_pid=""
}

# One export, the proto3 JSON that the second argument names, through buf curl. It must answer
# with OTLP's full success: no span refused and no message (OTLP specification, "Full Success" and
# "Partial Success"). The sink leaves partial_success unset, and the Collector sets it empty. gRPC
# states a call's status in its trailers, which the load generators do not read, so this call
# checks what they cannot.
probe() {
    answer="$("${buf}" curl --schema examples/otlp/proto --protocol grpc $(reach) -d @"$2" \
        "$(url_of "$1" "${export_path}")" 2>"${work}/probe.log")" || true
    case "$(printf '%s' "${answer}" | tr -d ' \n')" in
        '{}' | '{"partialSuccess":{}}') return 0 ;;
    esac
    echo "fullstack: $1: the export $2 answered '${answer}'" >&2
    cat "${work}/probe.log" >&2
    return 1
}

# A receiver that validates must refuse the export of `broken.json` with `invalid_argument`
# (Connect protocol, "Error Codes"), so a run never times a server that checks no rule. The
# refused export adds no span to its count.
probe_refused() {
    case "$1" in
        *-validate) ;;
        *) return 0 ;;
    esac
    if "${buf}" curl --schema examples/otlp/proto --protocol grpc $(reach) -d @"${work}/broken.json" \
        "$(url_of "$1" "${export_path}")" >"${work}/refused.log" 2>&1; then
        echo "fullstack: $1 took an export that breaks a rule" >&2
        return 1
    fi
    grep -q '"code": "invalid_argument"' "${work}/refused.log" && return 0
    echo "fullstack: $1 refused an export that breaks a rule, but not with invalid_argument" >&2
    cat "${work}/refused.log" >&2
    return 1
}

# The spans a server says it took and refused. Vector counts one event for each span.
counted() {
    case "$1" in
        connect-zig | connect-zig-validate | connect-zig-generic | connect-go | connect-go-validate) curl -sS $(reach) "$(url_of "$1" /sink/count)" |
            awk '{ print $4, 0 }' ;;
        # connect-rust's server has no plain route, so its counts come from a port of their own.
        connect-rust | connect-rust-validate) curl -sS "http://127.0.0.1:${connect_rust_count_port}/" | awk '{ print $4, 0 }' ;;
        collector) metric_sum "http://127.0.0.1:${metrics_port}/metrics" \
            otelcol_receiver_accepted_spans otelcol_receiver_refused_spans ;;
        vector) metric_sum "http://127.0.0.1:${vector_metrics_port}/metrics" \
            'vector_component_received_events_total{component_id="otlp"' \
            'vector_component_discarded_events_total{component_id="otlp"' ;;
        rotel) metric_sum "http://127.0.0.1:${counter_metrics_port}/metrics" \
            rotel_receiver_accepted_spans rotel_receiver_refused_spans ;;
    esac
}

# The sums of the Prometheus samples whose lines start with the second and the third argument. A
# sample's value follows its name and labels, and a time may follow the value.
metric_sum() {
    curl -sS "$1" | awk -v taken="$2" -v refused="$3" '
        index($0, taken) == 1 { took += $2 }
        index($0, refused) == 1 { lost += $2 }
        END { printf "%d %d\n", took, lost }'
}

# Fails when a server's count differs from the spans it was sent, or it refused one. A count that
# lags reads again each second, `count_tries` times at most.
check_count() {
    for _ in $(seq 1 "${count_tries}"); do
        set -- "$1" "$2" $(counted "$1")
        [ "$4" -eq 0 ] || break
        [ "$3" -eq "$2" ] && return 0
        [ "$3" -lt "$2" ] || break
        sleep 1
    done
    echo "fullstack: $1 took $3 spans and refused $4, of $2 sent" >&2
    return 1
}

# connect-zig's sink must decode each export into its route's storage whole: a list that does not
# fit is decoded again by each read of it, and the benchmark would time that (decision 37).
check_storage() {
    case "$1" in
        connect-zig | connect-zig-validate | connect-zig-generic) ;;
        *) return 0 ;;
    esac
    past="$(curl -sS $(reach) "$(url_of "$1" /sink/count)" | awk '{ print $6 }')"
    [ "${past}" = 0 ] && return 0
    echo "fullstack: $1 decoded ${past:-an unknown count of} exports past its route's storage" >&2
    return 1
}

cpu_ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat"; }
# The busy and the total ticks of the load's cores, as `<busy>:<total>`, from /proc/stat. The
# server runs on none of them. Of user, nice, system, idle, iowait, irq, softirq and steal, every
# field but idle and iowait is busy; the guest fields that follow are already in user and nice.
# The ticks count all the work on those cores: oha's, and the kernel's for the traffic oha sends.
# With no core pinned, it gives `-`, and no step reads it.
load_ticks() {
    [ -n "${load_cores:-}" ] || { echo -; return; }
    awk -v cores="${load_cores}" 'BEGIN { split(cores, list, ","); for (i in list) want["cpu" list[i]] = 1 }
        $1 in want { for (f = 2; f <= 9; f++) { total += $f; if (f != 5 && f != 6) busy += $f } }
        END { print busy ":" total }' /proc/stat
}
peak_kb() { awk '/^VmHWM:/ { print $2 }' "/proc/$1/status"; }
