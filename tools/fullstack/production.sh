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
# tools/fullstack/load sends the exports at fixed rates, each connection on a schedule of its own,
# and counts each call's latency from the instant its schedule set, so the latency holds the time a
# call waited in a queue. It opens its 516 connections once, over TLS 1.3 with
# TLS_AES_128_GCM_SHA256 alone, and keeps them across the climb, as the agents keep theirs. Each
# connection sends its class's variants in turn, so a decoder does not read the same octets on
# every call. The rate climbs one step at a time. A step fails when its p99 passes 100 ms, when a
# call is refused, or when the core takes less than 95% of the step's spans. The load runs on two
# cores of its own, and the server on a third. A step that fails while the load's cores were 90%
# busy or more ends as "load": the load, not the server, may have set the limit, so the rate held
# is a floor. Then five more steps halve the gap between the last step that passed and the step
# that failed (tools/fullstack/production_step.py). The server runs once for the whole climb, and
# its count of spans must equal what it was sent.

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
# Variants of each class's export, which the load sends in turn.
production_variants=32
# Calls in flight on one connection at most, as the otlp exporter's queue sends them.
connection_streams=4
p99_limit_ms=100
# What tools/fullstack/compression.sh sets for exports in a coding: the end of their files' names,
# and the coding grpc-encoding names, none for exports with no coding. The production part sends
# the gzip exports of tools/fullstack/production_request.py.
production_tag=""
production_encoding=gzip

# The file of a class's variant of its export: variant 0 is `production-<spans>`, which the probes
# and the reports read, and variant n is `production-<spans>-v<n>`.
production_file() {
    suffix=""
    [ "$2" -eq 0 ] || suffix="-v$2"
    echo "${work}/production-$1${suffix}${3:-}.grpc"
}

# Each class's variants with the tag, joined by commas.
production_files() {
    files=""
    for variant in $(seq 0 $((production_variants - 1))); do
        files="${files:+${files},}$(production_file "$1" "${variant}" "$2")"
    done
    echo "${files}"
}

# Writes each class's variants of its export: its proto3 JSON, its encoding, and its encoding in
# gzip. The variants of a class run at once, since each waits for buf.
production_exports() {
    for class in ${production_classes}; do
        spans="${class%%:*}" writers=""
        for variant in $(seq 0 $((production_variants - 1))); do
            python3 tools/fullstack/production_request.py "${buf}" "${spans}" \
                "$(production_file "${spans}" "${variant}")" "${variant}" >/dev/null &
            writers="${writers} $!"
        done
        for writer in ${writers}; do wait "${writer}"; done
    done
}

# Starts the climb's load on the server: one process, whose connections stay open across the
# climb's steps. It reads its commands from one FIFO and answers on another, and it names the TLS
# suite each connection runs.
load_start() {
    rm -f "${work}/load-in" "${work}/load-out"
    mkfifo "${work}/load-in" "${work}/load-out"
    classes=""
    for class in ${production_classes}; do
        classes="${classes} --class ${class}:$(production_files "${class%%:*}" "${production_tag}")"
    done
    trust=""
    [ "${transport}" = tls ] && trust="--ca ${ca}"
    ${load_pin} "${fullstack_load}" --address "127.0.0.1:$(port_of "$1")" --path "${export_path}" \
        ${trust} --encoding "${production_encoding}" --streams "${connection_streams}" \
        --threads "${load_threads}" ${classes} \
        <"${work}/load-in" >"${work}/load-out" 2>"${work}/load.log" &
    load_pid=$!
    exec 7>"${work}/load-in" 8<"${work}/load-out"
    read -r word connections suite <&8 || word=""
    if [ "${word}" != ready ]; then
        echo "fullstack: the load did not start on $1: $(cat "${work}/load.log")" >&2
        load_stop
        return 1
    fi
    [ "${transport}" = tls ] && echo "suite ${transport} $1 ${suite}"
    return 0
}

load_stop() {
    kill -0 "${load_pid}" 2>/dev/null && echo quit >&7
    exec 7>&- 8<&-
    wait "${load_pid}" || true
    load_pid=""
    rm -f "${work}/load-in" "${work}/load-out"
}

# One step of the load: every connection sends at the rate for the step's seconds, and the load
# writes a CSV file for each class. It sets `reopened` to the connections the load opened again
# before the step, because the server had closed them.
production_load() {
    rm -f "${work}"/step-*.csv
    # A write to a FIFO whose reader is gone would end this script with SIGPIPE.
    kill -0 "${load_pid}" 2>/dev/null || { echo "fullstack: the load ended on $1" >&2; return 1; }
    echo "step $2 ${step_seconds} ${work}" >&7
    read -r word _ reopened <&8 || word=""
    [ "${word}" = done ] && return 0
    echo "fullstack: the load ended on $1: $(cat "${work}/load.log")" >&2
    return 1
}

# One step of the server at a rate: a line of its results. It adds the spans the server took to
# `sent`, and sets `verdict`. It fails when the load ends.
production_step() {
    step_rate="$2"
    echo "fullstack: production, ${transport}, $1, ${step_rate} a connection a second" >&2
    before="$(cpu_ticks "${server_pid}")"
    load_before="$(load_ticks)"
    started_ns="$(date +%s%N)"
    production_load "$1" "${step_rate}" || return 1
    ended_ns="$(date +%s%N)"
    after="$(cpu_ticks "${server_pid}")"
    load_after="$(load_ticks)"
    set -- $(python3 tools/fullstack/production_step.py "${work}" "${step_seconds}" \
        "${p99_limit_ms}" "${step_rate}" "${load_before}" "${load_after}" ${production_classes})
    sent=$((sent + $1))
    # The step's wall time, in milliseconds, over which the server's CPU ticks count, and the
    # connections the load opened again before it.
    echo "step ${transport} ${server} ${step_rate} $* $((after - before)) $(((ended_ns - started_ns) / 1000000)) ${reopened}"
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
    load_start "${server}" || { stop; return 1; }
    passed="" failed=""
    for rate in ${production_steps}; do
        production_step "${server}" "${rate}" || { load_stop; stop; return 1; }
        [ "${verdict}" = pass ] || { failed="${rate}"; break; }
        passed="${rate}"
    done
    if [ -n "${passed}" ] && [ -n "${failed}" ]; then
        for _ in $(seq 1 "${refine_rounds}"); do
            # A step that failed leaves calls in the server's queue.
            sleep "${rest_seconds}"
            rate="$(awk "BEGIN { print (${passed} + ${failed}) / 2 }")"
            production_step "${server}" "${rate}" || { load_stop; stop; return 1; }
            if [ "${verdict}" = pass ]; then passed="${rate}"; else failed="${rate}"; fi
        done
    fi
    load_stop
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
            "$(getconf CLK_TCK)" "${load_text}" "${collector}" "${vector_text}" \
            "${rotel_text}" "${connect_go_text}" "${connect_rust_text}" "${commit}" "${placement}" \
            "${step_seconds}" "${production_variants}" "${p99_limit_ms}" ${production_classes}
        echo
    done
    transport=tls
}
