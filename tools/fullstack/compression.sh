# shellcheck shell=sh
# The compression part of tools/fullstack_check.sh (design §8 step 37, decision 46 as amended),
# which sources this file and runs `compression_part <transport>`: what each coding of an export
# costs the three Connect receivers, each on its library's own decoders: connect-zig's sink on
# stdx's, connect-go's on compress/gzip, klauspost/compress and andybalholm/brotli, and
# connect-rust's on flate2, zstd and brotli. Over TLS 1.3 or in cleartext h2, each receiver takes
# the production model's exports uncompressed, and in gzip, zstd and brotli, which `zig build
# otlp-compress` writes with stdx's encoders as a connect-zig client places them: gzip at stdx's
# default level, zstd and brotli at level 1.
#
# Each receiver runs both loads with each coding: the peak of tools/fullstack/peak.sh, on the
# production model's exports of 16 and 512 spans, and the climb of tools/fullstack/production.sh,
# on its mix, in rounds. Each round of the peak rotates the order of the codings and of the
# receivers, and each round of the climb gives each receiver its codings in an order of its own,
# so a runner that drifts over the job does not always slow the same coding. Each run checks
# every span, as theirs do.

compression_servers="connect-zig connect-go connect-rust"
compression_codings="identity gzip zstd br"

# Writes each class's variants of its export in each coding, and a line of the first variant's
# octets in each to `compression-octets`: the spans, the coding, the message's octets and the
# octets sent.
compression_exports() {
    : >"${work}/compression-octets"
    production_exports
    for class in ${production_classes}; do
        spans="${class%%:*}"
        for coding in ${compression_codings}; do
            for variant in $(seq 0 $((production_variants - 1))); do
                octets="$("${compress}" "${coding}" "$(production_file "${spans}" "${variant}").binpb" \
                    "$(production_file "${spans}" "${variant}" "-${coding}")")"
                if [ "${variant}" -eq 0 ]; then
                    echo "${spans} ${coding} ${octets}" >>"${work}/compression-octets"
                fi
            done
        done
    done
}

# The coding grpc-encoding names for an export: none for one in no coding.
encoding_of() {
    [ "$1" = identity ] || echo "$1"
}

# Each round of the peak, its codings and its receivers in the round's order.
compression_peak() {
    for coding in ${compression_codings}; do : >"${work}/compression-peak-${coding}"; done
    peak_export=production
    for round in $(seq 1 "${peak_rounds}"); do
        for spans in ${peak_spans}; do
            for coding in $(rotate $((round - 1)) ${compression_codings}); do
                peak_tag="-${coding}" peak_encoding="$(encoding_of "${coding}")"
                for server in $(rotate $((round - 1)) ${compression_servers}); do
                    echo "fullstack: compression, ${transport}, peak, round ${round}, ${server}, ${coding}, ${spans} spans" >&2
                    peak_measure "${server}" "${spans}" >>"${work}/compression-peak-${coding}" || status=1
                done
            done
        done
    done
    peak_export=export peak_tag="" peak_encoding=""
}

# Each receiver's climbs in each coding, `production_rounds` rounds of each. At each turn every
# receiver climbs once, and in round r the n-th receiver climbs its codings rotated by n + r - 1.
# A receiver's first climb steps up from the lowest rate, and its others search near the rate an
# earlier one held (tools/fullstack/production.sh, production_search).
compression_climbs() {
    for coding in ${compression_codings}; do : >"${work}/compression-climb-${coding}"; done
    rm -f "${work}"/held-*
    count="$(echo ${compression_codings} | wc -w)"
    for round in $(seq 1 "${production_rounds}"); do
        for turn in $(seq 0 $((count - 1))); do
            index=0
            for server in ${compression_servers}; do
                coding="$(word_at "${turn}" $(rotate $((index + round - 1)) ${compression_codings}))"
                production_tag="-${coding}" production_encoding="$(encoding_of "${coding}")"
                production_climb "${server}" "${round}" >>"${work}/compression-climb-${coding}" || status=1
                index=$((index + 1))
            done
        done
    done
    production_tag="" production_encoding=gzip
}

compression_part() {
    transport="$1"
    # connect-zig's sink with room for more calls at once: an uncompressed export holds its call
    # longer while its octets arrive, and its climb would end on the calls and not on the core
    # (tools/otlp_sink/constants.zig, `requests_compression`).
    plain_sink="${sink}"
    sink="${sink_compression}"
    compression_exports
    compression_peak
    compression_climbs
    python3 tools/fullstack/compression_report.py "${work}" "${transport}" "$(getconf CLK_TCK)" \
        "$("${h2load}" --version | head -1)" "${load_text}" \
        "${connect_go_text}" "${connect_rust_text}" "${commit}" "${placement}" "${peak_rounds}" \
        "${step_seconds}" "${production_variants}" "${p99_limit_ms}" "${production_rounds}" \
        "${tls_suite}" "${compression_codings}" ${production_classes}
    echo
    sink="${plain_sink}"
    transport=tls
}
