#!/bin/sh
# Times protovalidate's implementations over one schema, and requires each to give each message
# the same verdict (docs/benchmarks.md, "Validation"):
#
# - connect-zig's protovalidate, `zig build bench-validate`, ReleaseFast;
# - protovalidate-go, bench/validate/go, over protoc-gen-go's code;
# - protovalidate-es on Node.js, bench/validate/node;
# - protovalidate-buffa and prost-protovalidate in Rust, bench/validate/rust.
#
#   tools/validate_compare_check.sh [--quick]
#
# bench/validate/proto holds the schema, and bench/validate/cases each message as JSON, which
# `buf convert` encodes. Each program validates each message, prints its verdict, "valid" or
# "invalid:" and the rule ids of the violations in order, and times one call as
# bench/measure.zig does. The script fails when two verdicts of one message differ, and prints
# one table of every time. `--quick` passes on to every program. Last it prints what each of
# connect-zig's calls takes on the CPU, `bench-validate --counters`: cycles, instructions,
# branches and branch misses, where the host's kernel lets a process count its own events.
#
# It needs buf, go, node with npm, and cargo, or BUF, GO, NPM and CARGO naming them.
# prost-protovalidate's build runs protoc: PROTOC names one, or the script downloads the release
# it pins into the cache, checked against its SHA-256.
set -eu
cd "$(dirname "$0")/.."
root="$(pwd)"
buf="${BUF:-buf}"
go="${GO:-go}"
npm="${NPM:-npm}"
cargo="${CARGO:-cargo}"
quick=""
[ "${1:-}" != "--quick" ] || quick="--quick"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# protoc 36.2, by the SHA-256 of each release asset as GitHub served it on 2026-11-21.
protoc_version="36.2"
protoc_for_host() {
    case "$(uname -s) $(uname -m)" in
        "Linux x86_64") echo "linux-x86_64 121f6c7afe1d4d0e3ea6aab9432038599250134cbf4474cb1167d2c7decd4278" ;;
        "Linux aarch64") echo "linux-aarch_64 8b8f18bd2b30346efbc698dd5a73dd7c805f3ef8380f6dfc95c768f3f1852f6a" ;;
        "Darwin arm64" | "Darwin x86_64") echo "osx-universal_binary 83d0dc80672f53486f54299bca6177159f9cad1fd54d4d3143eeea53c4423e1b" ;;
        *) echo "" ;;
    esac
}
protoc="${PROTOC:-}"
if [ -z "${protoc}" ]; then
    install="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/protoc-${protoc_version}"
    protoc="${install}/bin/protoc"
    if [ ! -x "${protoc}" ]; then
        asset="$(protoc_for_host)"
        [ -n "${asset}" ] || { echo "validate_compare_check.sh: no pinned protoc for $(uname -s) on $(uname -m); set PROTOC" >&2; exit 1; }
        archive="${work}/protoc.zip"
        curl -sSfL --retry 3 -o "${archive}" \
            "https://github.com/protocolbuffers/protobuf/releases/download/v${protoc_version}/protoc-${protoc_version}-${asset% *}.zip"
        if command -v sha256sum >/dev/null 2>&1; then
            echo "${asset#* }  ${archive}" | sha256sum -c -
        else
            echo "${asset#* }  ${archive}" | shasum -a 256 -c -
        fi
        rm -rf "${install}"
        mkdir -p "${install}"
        python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "${archive}" "${install}"
        chmod +x "${protoc}"
    fi
fi

# The schema and its imports alone: prost-build reads no file of an edition, which other
# schemas of the workspace are.
cases="${work}/cases"
mkdir -p "${cases}"
"${buf}" build . --path bench/validate/proto/bench/validate/v1/validate.proto -o "${cases}/set.binpb"
for file in bench/validate/cases/*.json; do
    name="$(basename "${file}" .json)"
    case "${name}" in
        small_*) type=Small ;;
        medium_*) type=Medium ;;
        *) type=Rules ;;
    esac
    "${buf}" convert "${cases}/set.binpb" --type "bench.validate.v1.${type}" --from "${file}" --to "${cases}/${name}.binpb"
done

zig build bench-validate -- ${quick} "${cases}" >"${work}/zig.md"
zig build bench-validate -- --counters "${cases}" >"${work}/zig_counters.md"
# Each program is built for this machine's CPU, as `zig build` builds for it: Go at the highest
# level of the CPU that it names, and Rust with `target-cpu=native`, in a directory named for the
# CPU (tools/host_cpu.sh).
. tools/host_cpu.sh
go_build="$(go_level)"
(cd bench/validate/go && env ${go_build:+"${go_build}"} "${go}" build -o "${work}/validate-go" .)
"${work}/validate-go" ${quick} "${cases}" >"${work}/go.md"
# npm installs the packages in a copy of the program, so the tree holds no node_modules.
mkdir -p "${work}/node"
cp bench/validate/node/package.json bench/validate/node/package-lock.json bench/validate/node/main.js "${work}/node/"
(cd "${work}/node" && "${npm}" ci --no-audit --no-fund --silent)
node "${work}/node/main.js" ${quick} "${cases}" >"${work}/node.md"
rust_target="${root}/.zig-cache/validate-rust-$(host_features)"
(cd bench/validate/rust && RUSTFLAGS="${rust_native}" PROTOC="${protoc}" VALIDATE_DESCRIPTORS="${cases}/set.binpb" \
    "${cargo}" build --quiet --release --target-dir "${rust_target}")
"${rust_target}/release/validate-rust" ${quick} "${cases}" >"${work}/buffa.md"
"${rust_target}/release/validate-rust" --prost ${quick} "${cases}" >"${work}/prost.md"

machine="$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1)"
[ -n "${machine}" ] || machine="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
python3 - "${work}" "${machine}, $(uname -m)" <<'PYTHON'
import sys

work, machine = sys.argv[1], sys.argv[2]
programs = [("Zig", "zig"), ("Go", "go"), ("Node", "node"), ("buffa", "buffa"), ("prost", "prost")]


def rows(name):
    table = {}
    for line in open(f"{work}/{name}.md", encoding="utf-8"):
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) == 4 and cells[0] not in ("case", "---"):
            table[cells[0]] = (cells[1], float(cells[2]), float(cells[3]))
    return table


tables = {label: rows(name) for label, name in programs}
cases = list(tables["Zig"])
wrong = []
print(f"Machine: {machine}")
print()
absent = ("", float("nan"), float("nan"))
for metric, column, title in [(2, "total", "decode and validate"), (1, "validate", "validate alone")]:
    print(f"Each cell is the nanoseconds of one call: {title}.")
    print()
    print("| case | verdict | " + " | ".join(f"{label} {column} ns" for label, _ in programs) + f" | Go {column} / Zig {column} |")
    print("| --- | --- | " + " | ".join("---:" for _ in programs) + " | ---: |")
    for case in cases:
        verdict = tables["Zig"][case][0]
        times = [tables[label].get(case, absent)[metric] for label, _ in programs]
        print(f"| {case} | {verdict} | " + " | ".join(f"{t:.1f}" for t in times) + f" | {times[1] / times[0]:.2f} |")
    print()
for case in cases:
    verdict = tables["Zig"][case][0]
    for label, _ in programs:
        if case not in tables[label]:
            wrong.append(f"{label} has no row for {case}")
        elif tables[label][case][0] != verdict:
            wrong.append(f"{case}: Zig says {verdict}, {label} says {tables[label][case][0]}")
if wrong:
    print("\n".join(wrong), file=sys.stderr)
    sys.exit(1)
print(f"Each of the {len(programs)} implementations gave each of the {len(cases)} messages the same verdict.")
PYTHON
echo
echo "connect-zig's counts of one call (bench/counters.zig):"
echo
cat "${work}/zig_counters.md"
