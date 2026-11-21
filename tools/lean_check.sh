#!/bin/sh
# Builds the Lean model of spec/lean/ with `zig build lean`, which also requires the committed
# vector file beside the Zig grammar to be what the model gives (spec/README.md).
# `zig build lean -- write` rewrites that file.
#
# It needs lake. With none on the path, and no LAKE naming one, it installs the Lean release
# that spec/lean/lean-toolchain pins into the cache, checked against a pinned SHA-256: x86-64
# Linux alone, as that is the one machine the model needs. It then needs curl, tar and zstd.
set -eu
cd "$(dirname "$0")/.."
version="4.34.0"
# SHA-256 of lean-4.34.0-linux.tar.zst, the digest GitHub records for the release's asset.
sha256_x86_64_linux="caaa98356098c85dc0fcbbd28e1ec66f39eb6551829972b752ff20e1286b646b"
pinned="$(cat spec/lean/lean-toolchain)"
if [ "${pinned}" != "leanprover/lean4:v${version}" ]; then
    echo "lean_check.sh: spec/lean/lean-toolchain pins ${pinned}, and this script installs ${version}" >&2
    exit 1
fi

lake="${LAKE:-}"
if [ -z "${lake}" ] && command -v lake >/dev/null 2>&1; then
    lake="$(command -v lake)"
fi
if [ -z "${lake}" ]; then
    if [ "$(uname -s) $(uname -m)" != "Linux x86_64" ]; then
        echo "lean_check.sh: no lake on the path, and no pinned Lean for $(uname -s) on $(uname -m)" >&2
        exit 1
    fi
    install="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/lean-${version}"
    lake="${install}/bin/lake"
    if [ ! -x "${lake}" ]; then
        archive="$(mktemp)"
        trap 'rm -f "${archive}"' EXIT
        curl -sSfL --retry 3 -o "${archive}" \
            "https://github.com/leanprover/lean4/releases/download/v${version}/lean-${version}-linux.tar.zst"
        echo "${sha256_x86_64_linux}  ${archive}" | sha256sum -c -
        rm -rf "${install}"
        mkdir -p "${install}"
        tar --zstd -xf "${archive}" -C "${install}" --strip-components=1
    fi
fi
"${lake}" --version
PATH="$(dirname "${lake}"):${PATH}" zig build lean
