#!/bin/sh
# Counts the instructions each benchmark operation takes, under callgrind, and fails when one
# takes more than `tolerance_percent` above bench/instructions.txt. A count does not move with
# the machine's load, so the check is as strict on a shared CI runner as on a quiet one; the wall
# time of `zig build bench` still answers how fast. The program is built for x86-64-v3 (AVX2, no
# AVX-512, which valgrind does not run), so every machine counts the same code paths.
#
#   tools/perf_check.sh            check against the baseline
#   tools/perf_check.sh --write    write the counts as the new baseline
#
# It needs valgrind 3.22 or newer, on x86-64. With PERF_REPORT naming a file, it appends a
# Markdown table of every operation there, and under GitHub Actions it marks each regression as
# an error annotation.
set -eu
cd "$(dirname "$0")/.."
baseline=bench/instructions.txt
report="${PERF_REPORT:-/dev/null}"
# A change may cost this much more than the baseline before the check fails, in percent. Counts
# repeat exactly on one build; the margin covers what another compiler build may reorder.
tolerance_percent=2
# The runs of each operation the program counts (bench/main.zig, instruction_iterations).
iterations=16
zig build install-bench -Dcpu=x86_64_v3
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
valgrind --tool=callgrind --collect-atstart=no --callgrind-out-file="${work}/out.%p" \
    zig-out/bin/bench --instructions >/dev/null 2>"${work}/valgrind.log" || {
    cat "${work}/valgrind.log" >&2
    exit 1
}
# One line for each operation: "<message> <operation>|<instructions of one run>".
for dump in "${work}"/out.*; do
    label="$(sed -n 's/^desc: Trigger: Client Request: //p' "${dump}")"
    [ -n "${label}" ] || continue
    total="$(sed -n 's/^totals: //p' "${dump}")"
    echo "${label}|$((total / iterations))"
done | sort >"${work}/counts.txt"
[ -s "${work}/counts.txt" ] || { echo "callgrind dumped no counts" >&2; exit 1; }

if [ "${1:-}" = "--write" ]; then
    {
        echo "# Instructions of one run of each benchmark operation, x86-64-v3, from tools/perf_check.sh."
        cat "${work}/counts.txt"
    } >"${baseline}"
    echo "wrote ${baseline}"
    exit 0
fi

{
    echo "## Performance: instructions of one operation, against ${baseline}"
    echo
    echo "| Operation | Baseline | Now | Change |"
    echo "| --- | ---: | ---: | ---: |"
} >>"${report}"
regressions=0
while IFS='|' read -r label count; do
    base="$(grep -F "${label}|" "${baseline}" | cut -d'|' -f2 || true)"
    if [ -z "${base}" ]; then
        echo "| ${label} | none | ${count} | new |" >>"${report}"
        echo "new: ${label}: ${count}"
        continue
    fi
    change="$(awk -v now="${count}" -v base="${base}" 'BEGIN { printf "%+.2f", (now - base) * 100 / base }')"
    over="$(awk -v now="${count}" -v base="${base}" -v limit="${tolerance_percent}" 'BEGIN { print (now > base * (1 + limit / 100)) }')"
    mark=""
    if [ "${over}" = 1 ]; then
        mark=" ❌"
        regressions=$((regressions + 1))
        echo "FAIL: ${label}: ${count} instructions, ${change}% over ${base}"
        [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=performance regression::${label}: ${change}% more instructions than the baseline"
    else
        echo "ok: ${label}: ${count} instructions, ${change}%"
    fi
    echo "| ${label} | ${base} | ${count} | ${change}%${mark} |" >>"${report}"
done <"${work}/counts.txt"
if [ "${regressions}" -ne 0 ]; then
    echo "${regressions} operation(s) take more than ${tolerance_percent}% more instructions; if that is the price of a change, run tools/perf_check.sh --write and say why in the commit" >&2
    exit 1
fi
echo "no operation takes more than ${tolerance_percent}% more instructions than the baseline"
