# shellcheck shell=sh
# The production part of tools/fullstack_check.sh (design §8 steps 29 and 30, decision 44), which
# sources this file: the traffic of one gateway core for a fleet of 33,000 servers. It climbs
# over TLS for connect-zig, the Collector and Vector, then in cleartext h2 for connect-zig, the
# Collector and Rotel, whose receiver has no TLS.
#
# Each server of the fleet runs a Collector agent, which exports its spans over OTLP/gRPC with
# gzip, the default of the Collector's otlp exporter. Each agent holds one TLS connection, through
# a load balancer, to a gateway tier of 64 cores, so one core holds 516 connections. 70% of them
# send exports of 16 spans, 25% exports of 128 spans, and 5% exports of 512 spans: most servers
# are quiet, and a few are busy. tools/fullstack/production_request.py writes each export.
#
# oha sends the exports at fixed rates, one process for each size, with its latency correction,
# so the latency holds the time a call waited in a queue. The rate climbs one step at a time. A
# step fails when its p99 passes 100 ms, when a call is refused, or when the core takes less than
# 95% of the step's spans. Then three more steps halve the gap between the last step that passed
# and the step that failed. Each step opens its connections again, so the report leaves out its
# first 2 seconds, where the TLS handshakes fall. The server runs once for the whole climb, and
# its count of spans must equal what it was sent.

# Each class: the spans of its export, and the connections that send it.
production_classes="16:361 128:129 512:26"
# The exports each connection sends a second, at each step. At 1, the core takes 35,600 spans a
# second.
production_steps="0.25 0.5 0.75 1 1.5 2 3 4 6 8 10 12 16 20 24 32"
# Halvings of the gap between the last step that passed and the step that failed. The steps grow
# by up to half, so three halvings place the rate a core holds within 1/16 of it.
refine_rounds=3
rest_seconds=5
step_seconds=10
warm_seconds=2
# Calls in flight on one connection at most, as the otlp exporter's queue sends them.
connection_streams=4
p99_limit_ms=100

for class in ${production_classes}; do
    spans="${class%%:*}"
    python3 tools/fullstack/production_request.py "${buf}" "${spans}" \
        "${work}/production-${spans}.grpc" >&2
done

# One step: oha sends each class at the step's rate, into a CSV file for each class.
production_load() {
    loads=""
    for class in ${production_classes}; do
        spans="${class%%:*}" connections="${class##*:}"
        calls="$(awk "BEGIN { print $2 * ${connections} }")"
        trust=""
        [ "${transport}" = tls ] && trust="--cacert ${ca}"
        ${load_pin} "${oha}" --no-tui --http2 -c "${connections}" -p "${connection_streams}" \
            -q "${calls}" -z "${step_seconds}s" -w --latency-correction ${trust} -m POST \
            -D "${work}/production-${spans}.grpc" -H 'content-type: application/grpc' \
            -H 'te: trailers' -H 'grpc-encoding: gzip' --output-format csv \
            "$(url_of "$1" "${export_path}")" \
            >"${work}/step-${spans}.csv" 2>"${work}/step-${spans}.log" &
        loads="${loads} $!"
    done
    for load in ${loads}; do wait "${load}" || true; done
}

# One step of the server at a rate: a line of its results. It adds the spans the server took to
# `sent`, and sets `verdict`.
production_step() {
    step_rate="$2"
    echo "fullstack: production, ${transport}, $1, ${step_rate} a connection a second" >&2
    before="$(cpu_ticks "${server_pid}")"
    production_load "$1" "${step_rate}"
    after="$(cpu_ticks "${server_pid}")"
    set -- $(python3 tools/fullstack/production_step.py "${work}" "${warm_seconds}" \
        "${step_seconds}" "${p99_limit_ms}" "${step_rate}" ${production_classes})
    sent=$((sent + $1))
    echo "step ${transport} ${server} ${step_rate} $* $((after - before))"
    verdict="$7"
}

# The climb of one server: a line of the results for each step, until a step fails. Then the
# rate between the last step that passed and the step that failed, halved `refine_rounds` times,
# and the server's peak memory. It fails when the server answers a probe wrongly or miscounts.
production_climb() {
    server="$1"
    start "${server}" || { stop; return 1; }
    sent=0
    for class in ${production_classes}; do
        probe "${server}" "${work}/production-${class%%:*}.grpc.json" || { stop; return 1; }
        sent=$((sent + ${class%%:*}))
    done
    passed="" failed=""
    for rate in ${production_steps}; do
        production_step "${server}" "${rate}"
        [ "${verdict}" = pass ] || { failed="${rate}"; break; }
        passed="${rate}"
    done
    if [ -n "${passed}" ] && [ -n "${failed}" ]; then
        for _ in $(seq 1 "${refine_rounds}"); do
            # A step that failed leaves calls in the server's queue.
            sleep "${rest_seconds}"
            rate="$(awk "BEGIN { print (${passed} + ${failed}) / 2 }")"
            production_step "${server}" "${rate}"
            if [ "${verdict}" = pass ]; then passed="${rate}"; else failed="${rate}"; fi
        done
    fi
    echo "memory ${transport} ${server} $(peak_kb "${server_pid}")"
    check_count "${server}" "${sent}" || { stop; return 1; }
    stop
}

: >"${work}/production-results"
for transport in tls cleartext; do
    case "${transport}" in
        tls) servers="connect-zig collector vector connect-go connect-rust" ;;
        *) servers="connect-zig collector rotel" ;;
    esac
    for server in ${servers}; do
        production_climb "${server}" >>"${work}/production-results" || status=1
    done
    python3 tools/fullstack/production_report.py "${work}/production-results" "${transport}" \
        "$(getconf CLK_TCK)" "$("${oha}" --version | head -1)" "${collector}" "${vector_text}" \
        "${rotel_text}" "${connect_go_text}" "${connect_rust_text}" "${commit}" "${placement}" \
        "${step_seconds}" "${warm_seconds}" \
        "${p99_limit_ms}" "${tls_suite}" ${production_classes}
    echo
done
transport=tls
