#!/bin/sh
# Runs the protobuf benchmark in Zig (`zig build bench`), in Go (bench/go) and, when cargo is on
# the path, in Rust (bench/rust, on Buffa). It checks that each baseline encodes each message to
# the same bytes as Zig and decodes it to the same walk sum, and prints the tables side by side.
# `--quick` passes on to every program. It needs go on the path, or GO naming it; the Rust
# program also needs buf, or BUF naming it, for the descriptor set its build compiles.
set -eu
cd "$(dirname "$0")/.."
go="${GO:-go}"
cargo="${CARGO:-cargo}"
buf="${BUF:-buf}"
quick=""
if [ "${1:-}" = "--quick" ]; then
    quick="--quick"
fi
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

# The CPU's features: the first CPU's `flags` line on x86-64, and its `Features` line on aarch64.
# Runners that report the same model have different features, so a hash of them names a machine
# better than the model does.
cpu_features="$(sed -n -e 's/^flags[[:space:]]*: //p' -e 's/^Features[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null |
    head -n 1 | sha256sum | cut -c1-12)"

# The CPU's model, which the report names, so two runs' times compare only on the same kind of
# machine (docs/performance.md). lscpu names an arm64 core that /proc/cpuinfo leaves unnamed, and
# macOS has neither.
cpu_model() {
    if command -v lscpu >/dev/null 2>&1; then
        lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1
    elif [ "$(uname -s)" = "Darwin" ]; then
        sysctl -n machdep.cpu.brand_string
    else
        echo "unknown"
    fi
}

zig build bench -- ${quick} --write "${scratch}/zig" >"${scratch}/zig.md"
(cd bench/go && "${go}" run . ${quick} --write "${scratch}/go") >"${scratch}/go.md"
baselines="go"
if command -v "${cargo}" >/dev/null 2>&1; then
    "${buf}" build bench/proto --as-file-descriptor-set -o "${scratch}/bench.binpb"
    # Cargo's build lives outside the repository, as interop/rust/run.sh keeps its own. It runs
    # from bench/rust, whose .cargo/config.toml builds for this machine's CPU, as Zig does.
    # The build targets this machine's CPU, and CI caches the directory across runners, so the
    # directory is named for the CPU's features: a build from a CPU with other features stops on
    # an instruction this one lacks (SIGILL), as a build script did on CI run 62.
    target="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/bench-rust-target-${cpu_features}"
    (cd bench/rust && BENCH_DESCRIPTORS="${scratch}/bench.binpb" CARGO_TARGET_DIR="${target}" \
        "${cargo}" build --quiet --locked --release)
    "${target}/release/bench-rust" ${quick} --write "${scratch}/rust" >"${scratch}/rust.md"
    baselines="go rust"
else
    echo "cargo is not on the path: the Rust columns read absent" >&2
    : >"${scratch}/rust.md"
fi

status=0
for baseline in ${baselines}; do
    label="Go"
    [ "${baseline}" = "rust" ] && label="Rust"
    for message in small medium large deep varints strings tree packed; do
        for kind in bin sum; do
            if cmp -s "${scratch}/zig/${message}.${kind}" "${scratch}/${baseline}/${message}.${kind}"; then
                echo "${message}.${kind}: Zig and ${label} match"
            else
                echo "${message}.${kind}: Zig and ${label} differ" >&2
                status=1
            fi
        done
    done
done
echo
echo "Machine: $(uname -m), $(cpu_model), $(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "?") CPUs, features ${cpu_features}"
echo

# Each table row is "| message | operation | bytes | ns/op | MB/s |". The Zig row and the Go and
# Rust rows with the same message and operation make one row here. A baseline with no such row
# shows "absent" in its cells.
awk -F' [|] ' '
    FNR == 1 { file++ }
    !/^[|] [a-z]/ || /^[|] message/ { next }
    {
        sub(/^[|] /, "", $1)
        sub(/ [|]$/, "", $5)
        key = $1 "|" $2
        if (file == 1) order[++rows] = key
        bytes[file, key] = $3; ns[file, key] = $4; rate[file, key] = $5
    }
    function cell(table, file, key) {
        return ((file, key) in table) ? table[file, key] : "absent"
    }
    function ratio(file, key) {
        if (!((file, key) in ns) || ns[1, key] <= 0) return "absent"
        return sprintf("%.2f", ns[file, key] / ns[1, key])
    }
    END {
        print "| message | operation | Zig bytes | Go bytes | Rust bytes | Zig ns/op | Go ns/op | Rust ns/op | Zig MB/s | Go MB/s | Rust MB/s | Go time / Zig time | Rust time / Zig time |"
        print "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
        for (i = 1; i <= rows; i++) {
            key = order[i]
            split(key, part, "|")
            printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", part[1], part[2],
                bytes[1, key], cell(bytes, 2, key), cell(bytes, 3, key),
                ns[1, key], cell(ns, 2, key), cell(ns, 3, key),
                rate[1, key], cell(rate, 2, key), cell(rate, 3, key),
                ratio(2, key), ratio(3, key)
        }
    }
' "${scratch}/zig.md" "${scratch}/go.md" "${scratch}/rust.md"
exit "${status}"
