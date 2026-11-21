#!/bin/sh
# Compares this library's verdicts on random CEL rules and random messages with those of
# protovalidate-go, which runs cel-go (decision 47).
#
#   tools/cel_differential_check.sh [seed...]
#
# For each seed, 1 when none is given, tools/cel_differential/generate.py writes a schema of
# rules, one message type a rule, and a file of encoded messages. The plugin writes the
# schema's Zig code, and `zig build cel-differential-runner` builds a program over it, which
# validates each message as each type. tools/cel_differential/reference does the same with
# protovalidate-go, from the schema's descriptors. tools/cel_differential/compare.py compares
# the two: valid, invalid with the violation's message, an expression that fails as it runs,
# and a rule that does not compile. It fails on a difference that
# tools/cel_differential/known.txt does not hold.
#
# CEL_DIFFERENTIAL_RULES and CEL_DIFFERENTIAL_MESSAGES set the rules and the messages of a
# seed: 200 and 40. It needs buf, or BUF naming it, python3 and go.
set -eu
cd "$(dirname "$0")/.."
root="$(pwd)"
rules="${CEL_DIFFERENTIAL_RULES:-200}"
messages="${CEL_DIFFERENTIAL_MESSAGES:-40}"
buf="${BUF:-buf}"
[ "$#" -ne 0 ] || set -- 1
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

zig build plugin
(cd tools/cel_differential/reference && go build -o "${work}/reference" .)
template="{\"version\":\"v2\",\"plugins\":[{\"local\":\"${root}/zig-out/bin/protoc-gen-connect-zig\",\"out\":\"gen\"}]}"
status=0
for seed in "$@"; do
    folder="${work}/${seed}"
    mkdir -p "${folder}/proto/diff/v1"
    # validate.proto and the descriptor.proto it imports, beside the schema: no registry is read.
    cp -R src/protovalidate/proto/. "${folder}/proto/"
    python3 tools/cel_differential/generate.py "${seed}" "${rules}" "${messages}" "${folder}"
    (cd "${folder}" && "${buf}" build proto -o set.binpb && "${buf}" generate --template "${template}" proto --path proto/diff)
    zig build cel-differential-runner -Dcel-differential="${folder}"
    zig-out/bin/cel-differential-runner "${folder}/messages.txt" >"${folder}/zig.txt" 2>"${folder}/refused.txt"
    "${work}/reference" "${folder}/set.binpb" "${folder}/messages.txt" >"${folder}/go.txt"
    echo "seed ${seed}:"
    python3 tools/cel_differential/compare.py "${folder}/proto/diff/v1/diff.proto" "${folder}/zig.txt" "${folder}/go.txt" "${folder}/refused.txt" tools/cel_differential/known.txt || status=1
done
exit "${status}"
