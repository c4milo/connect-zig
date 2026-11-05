#!/bin/sh
# Runs connectrpc's conformance suite against the conformance server: every case config.yaml
# declares, in Connect, gRPC and gRPC-Web, over h11 and h2 (decision 26). The cases of
# conformance/known_failing.txt fail on purpose, each for the reason the file gives.
#
# It downloads the runner, pinned by SHA-256, into a cache, unless CONNECTCONFORMANCE names one.
set -eu
cd "$(dirname "$0")/.."
version="1.0.4"
sha256="b0b69570a6fc0e0dc94820f209ba47ef26a2dd3e98ed3350ce7fadd00bb51053"
runner="${CONNECTCONFORMANCE:-}"
if [ -z "${runner}" ]; then
    cache="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/conformance-${version}"
    runner="${cache}/connectconformance"
    if [ ! -x "${runner}" ]; then
        mkdir -p "${cache}"
        archive="${cache}/runner.tgz"
        curl -sSfL -o "${archive}" \
            "https://github.com/connectrpc/conformance/releases/download/v${version}/connectconformance-v${version}-Linux-x86_64.tar.gz"
        echo "${sha256}  ${archive}" | sha256sum -c -
        tar -xzf "${archive}" -C "${cache}" connectconformance
        rm -f "${archive}"
    fi
fi
zig build conformance-server
"${runner}" --mode server --conf conformance/config.yaml \
    --known-failing @conformance/known_failing.txt -- zig-out/bin/conformance-server
