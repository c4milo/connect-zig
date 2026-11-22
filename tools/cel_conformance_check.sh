#!/bin/sh
# Runs cel-spec's conformance suite against the code that protovalidate's CEL rules compile
# into (decision 47).
#
#   tools/cel_conformance_check.sh
#
# The suite is tests/simple/testdata of cel-spec at the tag v0.25.3, the release whose language
# definition docs/specs holds. The script reads each file with buf, and
# tools/cel_conformance/generate.py writes a case for each test that declares no variables and
# builds no message. `zig build cel-conformance-runner` compiles each case's expression as a
# rule's expression compiles, and the program prints each result.
# tools/cel_conformance/compare.py compares them with what the suite expects, and fails on a
# difference that tools/cel_conformance/known.txt does not hold.
#
# cel-spec is fetched at the tag's commit into a cache. CEL_SPEC names a checkout to read
# instead, which must be at that commit. It needs git, buf, or BUF naming it, and python3.
set -eu
cd "$(dirname "$0")/.."
version="0.25.3"
# The commit of the tag v0.25.3. A commit's id is the hash of its tree, so it pins every file.
commit="ba58ae5007845f3a1279b488cdeb79645ce958bb"
buf="${BUF:-buf}"
cache="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/cel-spec-${version}"
source="${CEL_SPEC:-${cache}/source}"

if [ -z "${CEL_SPEC:-}" ] && [ "$(git -C "${source}" rev-parse HEAD 2>/dev/null)" != "${commit}" ]; then
    rm -rf "${source:?}"
    mkdir -p "${source}"
    git -C "${source}" init -q
    git -C "${source}" fetch -q --depth 1 https://github.com/google/cel-spec "${commit}"
    git -C "${source}" checkout -q FETCH_HEAD
fi
[ "$(git -C "${source}" rev-parse HEAD)" = "${commit}" ]
# The suite tests the language that the code cites.
cmp docs/specs/cel/langdef.md "${source}/doc/langdef.md"
cmp docs/specs/cel/strings.md "${source}/doc/extensions/strings.md"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/json"
"${buf}" build "${source}/proto" -o "${work}/image.binpb"
for file in "${source}"/tests/simple/testdata/*.textproto; do
    name="$(basename "${file}" .textproto)"
    "${buf}" convert "${work}/image.binpb" --type cel.expr.conformance.test.SimpleTestFile \
        --from "${file}#format=txtpb" --to "${work}/json/${name}.json#format=json"
done
python3 -I tools/cel_conformance/generate.py "${work}" "${work}"/json/*.json
zig build cel-conformance-runner -Dcel-conformance="${work}"
zig-out/bin/cel-conformance-runner >"${work}/results.txt"
python3 -I tools/cel_conformance/compare.py "${work}/expected.json" "${work}/results.txt" tools/cel_conformance/known.txt
