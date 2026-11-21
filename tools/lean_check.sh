#!/bin/sh
# Builds the Lean model of spec/lean/ with `zig build lean`, which also requires the committed
# vector file beside the Zig grammar to be what the model gives (spec/README.md).
# `zig build lean -- write` rewrites that file.
#
#   tools/lean_check.sh [seed...]
#
# It then compares the model with the Zig grammar on random expressions. For each seed, the
# time in seconds when none is given, `lake exe vectors --random <seed> <count>` writes four
# kinds of text, `count` of each, 2500 unless LEAN_RANDOM_COUNT says: sequences of tokens with
# a space or nothing between two of them, sequences with spaces, chains of operands and
# operators with no brackets, and the texts of trees. `zig build cel-vectors-replay` builds the
# program that reads each text with the grammar the compiler runs, and requires the model's
# tree, or a refusal where the model has none. The script prints each seed, so a run that
# fails is run again with its seed.
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

# The model against the Zig grammar on expressions that a seed draws. The committed vectors are
# one fixed set, and each run of this part compares a set that no run compared before.
zig build cel-vectors-replay
count="${LEAN_RANDOM_COUNT:-2500}"
[ "$#" -ne 0 ] || set -- "$(date +%s)"
vectors="$(mktemp)"
trap 'rm -f "${vectors}" "${archive:-}"' EXIT
for seed in "$@"; do
    echo "seed ${seed}:"
    (cd spec/lean && PATH="$(dirname "${lake}"):${PATH}" "${lake}" exe vectors --random "${seed}" "${count}") >"${vectors}"
    zig-out/bin/cel-vectors-replay "${vectors}"
done
