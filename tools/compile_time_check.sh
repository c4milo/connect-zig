#!/bin/sh
# Holds what a schema's CEL rules cost the compiler to a baseline (docs/performance.md, "The
# compiler's time").
#
#   tools/compile_time_check.sh [--write]
#
# tools/compile_time/schema.py writes a schema of 30 message types of 20 fields, with 690 CEL
# rules, and the same schema with none. The script builds `zig build compile-time-subject` over
# each, five times in turns, and takes the least time of each. A time depends on the machine, so the
# check compares a ratio: the build with the rules over the build without them. It fails when
# the ratio passes the one bench/compile_time.txt holds by more than 12%, and prints the
# milliseconds a rule takes on this machine, which it does not compare. `--write` records the
# ratio: the commit that pays for a higher one says why.
#
# The unit tests hold the compiler's reading and typing of an expression to a count of
# branches, which is the same on each machine. This check holds the whole build, the code of
# each rule too, which no count states. It needs buf, or BUF naming it, and python3.
set -eu
cd "$(dirname "$0")/.."
root="$(pwd)"
messages=30
fields=20
rounds=5
tolerance_percent=12
baseline="bench/compile_time.txt"
buf="${BUF:-buf}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

zig build plugin
template="{\"version\":\"v2\",\"plugins\":[{\"local\":\"${root}/zig-out/bin/protoc-gen-connect-zig\",\"out\":\"gen\"}]}"
for variant in rules plain; do
    folder="${work}/${variant}"
    mkdir -p "${folder}/proto/timed/v1"
    # validate.proto and the descriptor.proto it imports, beside the schema: no registry is read.
    cp -R src/protovalidate/proto/. "${folder}/proto/"
    kind=""
    [ "${variant}" = rules ] || kind="plain"
    python3 tools/compile_time/schema.py "${messages}" "${fields}" ${kind} >"${folder}/proto/timed/v1/timed.proto"
    (cd "${folder}" && "${buf}" generate --template "${template}" proto --path proto/timed)
done

# The timed builds keep their cache in the work folder, which the script removes: each one
# is a new program, and ten of them a run would fill the tree's cache.
# One build first, so that no timed build pays for the build of the build itself.
zig build compile-time-subject -Dcompile-time="${work}/plain" --cache-dir "${work}/cache" >/dev/null
# The least wall time of `rounds` builds over each schema, in milliseconds. The builds take
# turns, so a machine that slows for a while slows both. Each build has a number of its own,
# so none is read from the cache.
times="$(python3 - "${work}" "${rounds}" <<'PYTHON'
import subprocess, sys, time
work, rounds = sys.argv[1], int(sys.argv[2])
least = {"rules": None, "plain": None}
for round_number in range(rounds):
    for variant in least:
        command = ["zig", "build", "compile-time-subject", f"-Dcompile-time={work}/{variant}", f"-Dnonce={time.time_ns()}", "--cache-dir", f"{work}/cache"]
        start = time.monotonic()
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        taken = (time.monotonic() - start) * 1000
        least[variant] = taken if least[variant] is None else min(least[variant], taken)
print(round(least["rules"]), round(least["plain"]))
PYTHON
)"
rules_ms="${times% *}"
plain_ms="${times#* }"
expressions="$(grep -c 'expression: ' "${work}/rules/proto/timed/v1/timed.proto")"
python3 - "${rules_ms}" "${plain_ms}" "${expressions}" "${baseline}" "${tolerance_percent}" "${1:-}" <<'PYTHON'
import sys
rules_ms, plain_ms, expressions = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
baseline_path, tolerance, mode = sys.argv[4], int(sys.argv[5]), sys.argv[6]
ratio = rules_ms / plain_ms
print(f"{expressions} CEL rules: {rules_ms} ms with the rules, {plain_ms} ms without, {(rules_ms - plain_ms) / expressions:.2f} ms a rule on this machine")
if mode == "--write":
    header = "# The build of tools/compile_time_check.sh's schema with its CEL rules, as a multiple of its\n# build without them, from tools/compile_time_check.sh --write.\n"
    open(baseline_path, "w").write(f"{header}ratio|{ratio:.2f}\n")
    print(f"recorded the ratio {ratio:.2f}")
    sys.exit(0)
recorded = next(float(line.split("|")[1]) for line in open(baseline_path) if line.startswith("ratio|"))
change = (ratio / recorded - 1) * 100
print(f"ratio {ratio:.2f}, baseline {recorded:.2f}: {change:+.1f}%")
if change > tolerance:
    sys.exit(f"the CEL rules cost the compiler more than {tolerance}% past the baseline")
if change < -tolerance:
    print(f"the ratio is more than {tolerance}% under the baseline: record it with --write, so the gain is kept")
PYTHON
