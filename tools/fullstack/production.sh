# shellcheck shell=sh
# The production part of tools/fullstack_check.sh (design §8 steps 29 and 30, decision 44), which
# sources this file and runs `production_part`: the traffic of one gateway core for a fleet of
# 33,000 servers. It climbs over TLS for connect-zig, the Collector, Vector and the receivers on
# connect-go and connect-rust, each Connect receiver also validating each export against
# tools/fullstack/validate's rules, then in cleartext h2 for connect-zig, the Collector and Rotel,
# whose receiver has no TLS. tools/fullstack/compression.sh runs `production_climb` too.
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
# 95% of the step's spans. A step that fails while the load's cores were 90% busy or more ends as
# "load": the load, not the server, may have set the limit, so the rate held is a floor. Then five
# more steps halve the gap between the last step that passed and the step that failed. Each step opens its connections again, so the measure leaves out its
# first 2 seconds, where the TLS handshakes fall, for latency and refusals alike; the report counts
# the calls refused then (tools/fullstack/production_step.py). The server runs once for the whole
# climb, and its count of spans must equal what it was sent.

# Each class: the spans of its export, and the connections that send it.
production_classes="16:361 128:129 512:26"
# The exports each connection sends a second, at each step. At 1, the core takes 35,600 spans a
# second. An x86-64 core of connect-zig passed 32 in CI's run 256, so the steps reach 48.
production_steps="0.25 0.5 0.75 1 1.5 2 3 4 6 8 10 12 16 20 24 32 40 48"
# Halvings of the gap between the last step that passed and the step that failed. The steps grow
# by up to half, so five halvings place the rate a core holds within 1/64 of it: a cost of a few
# percent, such as validation's or a coding's, then shows (decision 44 as amended).
refine_rounds=5
rest_seconds=5
step_seconds=10
warm_seconds=2
# Calls in flight on one connection at most, as the otlp exporter's queue sends them.
connection_streams=4
p99_limit_ms=100
# What tools/fullstack/compression.sh sets for exports in a coding: the end of their files' names,
# and the coding grpc-encoding names, none for exports with no coding. The production part sends
# the gzip exports of tools/fullstack/production_request.py.
production_tag=""
production_encoding=gzip

# Writes each class's export: its proto3 JSON, its encoding, and its encoding in gzip.
production_exports() {
    for class in ${production_classes}; do
        spans="${class%%:*}"
        python3 tools/fullstack/production_request.py "${buf}" "${spans}" \
            "${work}/production-${spans}.grpc" >&2
    done
}

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
            -D "${work}/production-${spans}${production_tag}.grpc" \
            -H 'content-type: application/grpc' -H 'te: trailers' \
            ${production_encoding:+-H "grpc-encoding: ${production_encoding}"} --output-format csv \
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
    load_before="$(load_ticks)"
    production_load "$1" "${step_rate}"
    after="$(cpu_ticks "${server_pid}")"
    load_after="$(load_ticks)"
    set -- $(python3 tools/fullstack/production_step.py "${work}" "${warm_seconds}" \
        "${step_seconds}" "${p99_limit_ms}" "${step_rate}" "${load_before}" "${load_after}" \
        ${production_classes})
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
    probe_refused "${server}" || { stop; return 1; }
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
    check_storage "${server}" || { stop; return 1; }
    stop
}

production_part() {
    production_exports
    : >"${work}/production-results"
    for transport in tls cleartext; do
        case "${transport}" in
            tls) servers="connect-zig connect-zig-validate collector vector connect-go connect-go-validate connect-rust connect-rust-validate" ;;
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
}
