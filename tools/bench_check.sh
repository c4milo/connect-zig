#!/bin/sh
# Runs the protobuf benchmark in Zig (`zig build bench`) and in Go (bench/go), checks that both
# encode each message to the same bytes and decode it to the same walk sum, and prints the two
# tables side by side. `--quick` passes on to both programs. It needs go on the path, or GO
# naming it.
set -eu
cd "$(dirname "$0")/.."
go="${GO:-go}"
quick=""
if [ "${1:-}" = "--quick" ]; then
    quick="--quick"
fi
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

zig build bench -- ${quick} --write "${scratch}/zig" >"${scratch}/zig.md"
(cd bench/go && "${go}" run . ${quick} --write "${scratch}/go") >"${scratch}/go.md"

status=0
for message in small medium large deep; do
    for kind in bin sum; do
        if cmp -s "${scratch}/zig/${message}.${kind}" "${scratch}/go/${message}.${kind}"; then
            echo "${message}.${kind}: Zig and Go match"
        else
            echo "${message}.${kind}: Zig and Go differ" >&2
            status=1
        fi
    done
done
echo

# Each table row is "| message | operation | bytes | ns/op | MB/s |". The Zig row and the Go row
# with the same message and operation make one row here.
awk -F' [|] ' '
    FNR == 1 { file++ }
    !/^[|] [a-z]/ || /^[|] message/ { next }
    {
        sub(/^[|] /, "", $1)
        sub(/ [|]$/, "", $5)
        key = $1 "|" $2
        if (file == 1) {
            order[++rows] = key
            zig_bytes[key] = $3; zig_ns[key] = $4; zig_rate[key] = $5
        } else {
            go_bytes[key] = $3; go_ns[key] = $4; go_rate[key] = $5
        }
    }
    END {
        print "| message | operation | Zig bytes | Go bytes | Zig ns/op | Go ns/op | Zig MB/s | Go MB/s | Go time / Zig time |"
        print "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
        for (i = 1; i <= rows; i++) {
            key = order[i]
            split(key, part, "|")
            ratio = zig_ns[key] > 0 ? go_ns[key] / zig_ns[key] : 0
            printf "| %s | %s | %s | %s | %s | %s | %s | %s | %.2f |\n", part[1], part[2],
                zig_bytes[key], go_bytes[key], zig_ns[key], go_ns[key], zig_rate[key], go_rate[key], ratio
        }
    }
' "${scratch}/zig.md" "${scratch}/go.md"
exit "${status}"
