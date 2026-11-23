# shellcheck shell=sh
# tools/fullstack_check.sh, and the files it sources beside this one, set the variables this
# file reads, which shellcheck cannot see when it reads this file alone.
# shellcheck disable=SC2154
# The peak part of tools/fullstack_check.sh (design §8 step 28, decision 44), which sources this
# file and runs `peak_part`: over TLS, h2load sends one export, again and again, on 16 connections
# of 4 streams, as fast as each server answers: connect-zig, the Collector, Vector, and the
# receivers on connect-go and connect-rust, each Connect receiver also validating each export
# against tools/fullstack/validate's rules. The exports hold 16 spans and 512, from
# tools/fullstack/otlp_request.py. Each round starts each server again, in turns, and the report
# gives the median of the rounds. tools/fullstack/compression.sh runs `peak_measure` too.

peak_spans="16 512"
# connect-go-memory is connect-go with the memory connect-zig's sink holds, and its collector
# turned off below it (tools/fullstack/servers.sh, go_memory).
peak_servers="connect-zig connect-zig-generic connect-zig-validate collector vector connect-go connect-go-memory connect-go-validate connect-rust connect-rust-validate"
peak_rounds=3
# The requests of each round for each export, after warm requests that are never counted.
peak_requests_of() { case "$1" in 16) echo 40000 ;; *) echo 4000 ;; esac; }
warm_divisor=10
# 16 connections of 4 streams each: 64 calls in flight, which the sink's router holds at once.
peak_connections=16
peak_streams=4
# What tools/fullstack/compression.sh sets for an export in a coding: the start of its file's
# name, the end of it, and the coding grpc-encoding names. The peak part sends the exports of
# tools/fullstack/otlp_request.py, with no coding.
peak_export="export"
peak_tag=""
peak_encoding=""

# h2load's calls of one export, with its report on standard output.
peak_load() {
    ${load_pin} "${h2load}" -n "$3" -c "${peak_connections}" -m "${peak_streams}" \
        -t "${load_threads}" \
        --tls13-ciphers="${tls_suite}" --ciphers="${tls12_cipher}" \
        -d "${work}/${peak_export}-$2${peak_tag}.grpc" \
        -H 'content-type: application/grpc' -H 'te: trailers' \
        ${peak_encoding:+-H "grpc-encoding: ${peak_encoding}"} ${4:+"--log-file=$4"} \
        "$(url_of "$1" "${export_path}")"
}

# One round of a server and an export: a line of the results, or a failure. The caller tests its
# status, so `set -e` stops nothing here, and each failure returns by name.
peak_measure() {
    server="$1" spans="$2" requests="$(peak_requests_of "$2")"
    warm=$((requests / warm_divisor))
    start "${server}" || { stop; return 1; }
    probe "${server}" "${work}/${peak_export}-${spans}.grpc.json" || { stop; return 1; }
    probe_refused "${server}" || { stop; return 1; }
    peak_load "${server}" "${spans}" "${warm}" >"${work}/warm.txt"
    # h2load appends to its log, so each round starts with none.
    rm -f "${work}/calls.log"
    before="$(cpu_ticks "${server_pid}")"
    peak_load "${server}" "${spans}" "${requests}" "${work}/calls.log" >"${work}/load.txt"
    after="$(cpu_ticks "${server_pid}")"
    peak="$(peak_kb "${server_pid}")"
    succeeded="$(awk '/^requests:/ { print $8 }' "${work}/load.txt")"
    # The probe's export, the warm ones and the measured ones.
    check_count "${server}" $(((1 + warm + requests) * spans)) || { stop; return 1; }
    check_storage "${server}" || { stop; return 1; }
    stop
    if [ "${succeeded}" -ne "${requests}" ]; then
        echo "fullstack: ${server}, ${spans} spans: ${succeeded} of ${requests} succeeded" >&2
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

peak_part() {
    for spans in ${peak_spans}; do
        python3 tools/fullstack/otlp_request.py "${buf}" "${spans}" "${work}/export-${spans}.grpc"
    done
    # shellcheck disable=SC2034 # the calls of tools/fullstack/servers.sh read transport
    transport=tls
    : >"${work}/peak-results"
    for round in $(seq 1 "${peak_rounds}"); do
        for spans in ${peak_spans}; do
            for server in ${peak_servers}; do
                echo "fullstack: peak, round ${round}, ${server}, ${spans} spans" >&2
                # shellcheck disable=SC2034 # tools/fullstack_check.sh exits with status
                peak_measure "${server}" "${spans}" >>"${work}/peak-results" || status=1
            done
        done
    done
    loader="$("${h2load}" --version | head -1)"
    python3 tools/fullstack/peak_report.py "${work}" "$(getconf CLK_TCK)" "${loader}" \
        "${collector}" "${vector_text}" "${connect_go_text}" "${connect_rust_text}" "${commit}" \
        "${placement}" "${peak_rounds}" "${peak_connections}" "${peak_streams}" \
        "${tls_suite}, or ${tls12_cipher} in TLS 1.2 for Vector" "${go_memory_limit}"
    echo
}
