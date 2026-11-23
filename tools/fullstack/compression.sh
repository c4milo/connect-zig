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
# on its mix. Each round of the peak rotates the order of the codings and of the receivers, and
# each receiver climbs its codings in an order of its own, so a runner that drifts over the job
# does not always slow the same coding. Each run checks every span, as theirs do.

compression_servers="connect-zig connect-go connect-rust"
compression_codings="identity gzip zstd br"

# The words after the first, rotated left by the first: `rotate 1 a b c` prints `b c a`.
rotate() {
    by="$1"
    shift
    by=$((by % $#))
    front="" back=""
    index=0
    for word in "$@"; do
        if [ "${index}" -lt "${by}" ]; then front="${front} ${word}"; else back="${back} ${word}"; fi
        index=$((index + 1))
    done
    echo ${back} ${front}
}

# The word after the first at the place the first names, from 0: `word_at 1 a b c` prints `b`.
word_at() {
    place="$1"
    shift
    shift "${place}"
    echo "$1"
}

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

# Each receiver's climb in each coding. At each turn every receiver climbs once, and the n-th
# receiver climbs its codings rotated by n.
compression_climbs() {
    for coding in ${compression_codings}; do : >"${work}/compression-climb-${coding}"; done
    count="$(echo ${compression_codings} | wc -w)"
    for turn in $(seq 0 $((count - 1))); do
        index=0
        for server in ${compression_servers}; do
            coding="$(word_at "${turn}" $(rotate "${index}" ${compression_codings}))"
            production_tag="-${coding}" production_encoding="$(encoding_of "${coding}")"
            production_climb "${server}" >>"${work}/compression-climb-${coding}" || status=1
            index=$((index + 1))
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
        "${step_seconds}" "${production_variants}" "${p99_limit_ms}" "${tls_suite}" \
        "${compression_codings}" ${production_classes}
    echo
    sink="${plain_sink}"
    transport=tls
}
