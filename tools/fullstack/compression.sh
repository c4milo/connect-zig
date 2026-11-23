# shellcheck shell=sh
# The compression part of tools/fullstack_check.sh (design §8 step 37, decision 46 as amended),
# which sources this file and runs `compression_part <transport>`: what each coding of an export
# costs the three Connect receivers, connect-zig's sink on stdx's decoders, connect-go's on
# compress/gzip, klauspost/compress and andybalholm/brotli, and connect-rust's on flate2, zstd and
# brotli. Over TLS 1.3 or in cleartext h2, each receiver takes exports in no coding, and in gzip,
# zstd and brotli, which `zig build otlp-compress` writes with stdx's encoders as a connect-zig
# client places them: gzip at stdx's default level, zstd and brotli at level 1.
#
# Each receiver runs both loads with each coding: the peak of tools/fullstack/peak.sh, on the
# exports of 16 and 512 spans, and the climb of tools/fullstack/production.sh, on the production
# model's mix. Each run checks every span, as theirs do.

compression_servers="connect-zig connect-go connect-rust"
compression_codings="identity gzip zstd br"

# Writes each export of both loads in each coding, and a line of its octets in each to
# `compression-octets`: the load, the spans, the coding, the message's octets and the octets sent.
compression_exports() {
    : >"${work}/compression-octets"
    for spans in ${peak_spans}; do
        python3 tools/fullstack/otlp_request.py "${buf}" "${spans}" "${work}/export-${spans}.grpc"
        for coding in ${compression_codings}; do
            echo "peak ${spans} ${coding} $("${compress}" "${coding}" "${work}/export-${spans}.grpc.binpb" \
                "${work}/export-${spans}-${coding}.grpc")" >>"${work}/compression-octets"
        done
    done
    production_exports
    for class in ${production_classes}; do
        spans="${class%%:*}"
        for coding in ${compression_codings}; do
            echo "production ${spans} ${coding} $("${compress}" "${coding}" \
                "${work}/production-${spans}.grpc.binpb" "${work}/production-${spans}-${coding}.grpc")" \
                >>"${work}/compression-octets"
        done
    done
}

# The coding grpc-encoding names for an export: none for one in no coding.
encoding_of() {
    [ "$1" = identity ] || echo "$1"
}

compression_part() {
    transport="$1"
    compression_exports
    for coding in ${compression_codings}; do : >"${work}/compression-peak-${coding}"; done
    for round in $(seq 1 "${peak_rounds}"); do
        for spans in ${peak_spans}; do
            for coding in ${compression_codings}; do
                peak_tag="-${coding}" peak_encoding="$(encoding_of "${coding}")"
                for server in ${compression_servers}; do
                    echo "fullstack: compression, ${transport}, peak, round ${round}, ${server}, ${coding}, ${spans} spans" >&2
                    peak_measure "${server}" "${spans}" >>"${work}/compression-peak-${coding}" || status=1
                done
            done
        done
    done
    peak_tag="" peak_encoding=""
    for coding in ${compression_codings}; do
        production_tag="-${coding}" production_encoding="$(encoding_of "${coding}")"
        : >"${work}/compression-climb-${coding}"
        for server in ${compression_servers}; do
            production_climb "${server}" >>"${work}/compression-climb-${coding}" || status=1
        done
    done
    production_tag="" production_encoding=gzip
    python3 tools/fullstack/compression_report.py "${work}" "${transport}" "$(getconf CLK_TCK)" \
        "$("${h2load}" --version | head -1)" "$("${oha}" --version | head -1)" \
        "${connect_go_text}" "${connect_rust_text}" "${commit}" "${placement}" "${peak_rounds}" \
        "${step_seconds}" "${p99_limit_ms}" "${tls_suite}" "${compression_codings}" ${production_classes}
    echo
    transport=tls
}
