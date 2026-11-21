#!/bin/sh
# Runs protovalidate's conformance harness against the program `zig build protovalidate-executor`
# builds (decision 47). The harness sends each case's message with the descriptors of the suite's
# schemas, and checks the violations the program answers: each one's field path, rule path, rule
# id and message, and whether rules that cannot be checked are told apart from a run-time error.
# The cases of conformance/protovalidate_known_failing.yaml fail on purpose, each under its
# reason; the harness fails when one of them passes, so a step that makes one pass removes its
# line.
#
# The harness is protovalidate's Go program, built from protovalidate's repository at the commit
# of its release, in a cache. PROTOVALIDATE_CONFORMANCE names a harness to use instead. The script
# also requires the schemas this tree keeps to be that commit's, and descriptor.proto to be
# protobuf's. It needs git and go.
set -eu
cd "$(dirname "$0")/.."
version="1.2.2"
# The commit of the tag v1.2.2. A commit's id is the hash of its tree, so it pins every file.
commit="4baed765070e580226a0a30bf2a357cc027dc1f7"
# protobuf v37.0-rc1's src/google/protobuf/descriptor.proto, which validate.proto imports.
descriptor_sha256="5768e01d4d45a70e0d9e44cfd42753e1312a0bf0deec599b657914f9d1bf6a1f"
cache="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/protovalidate-${version}"
source="${cache}/source"

if command -v sha256sum >/dev/null 2>&1; then
    echo "${descriptor_sha256}  src/protovalidate/proto/google/protobuf/descriptor.proto" | sha256sum -c -
else
    echo "${descriptor_sha256}  src/protovalidate/proto/google/protobuf/descriptor.proto" | shasum -a 256 -c -
fi

runner="${PROTOVALIDATE_CONFORMANCE:-}"
if [ -z "${runner}" ]; then
    runner="${cache}/protovalidate-conformance"
    if [ ! -x "${runner}" ] || [ "$(git -C "${source}" rev-parse HEAD 2>/dev/null)" != "${commit}" ]; then
        rm -rf "${source}"
        mkdir -p "${source}"
        git -C "${source}" init -q
        git -C "${source}" fetch -q --depth 1 https://github.com/bufbuild/protovalidate "${commit}"
        git -C "${source}" checkout -q FETCH_HEAD
        [ "$(git -C "${source}" rev-parse HEAD)" = "${commit}" ]
        (cd "${source}/tools" && go build -o "${runner}" ./protovalidate-conformance)
    fi
    # The schemas this tree generates its code from are the release's own.
    cmp src/protovalidate/proto/buf/validate/validate.proto "${source}/proto/protovalidate/buf/validate/validate.proto"
    (cd "${source}/proto/protovalidate-testing" && find buf/validate/conformance -name '*.proto' | sort) >"${cache}/schemas.txt"
    (cd conformance/protovalidate/proto && find buf/validate/conformance -name '*.proto' | sort) | cmp - "${cache}/schemas.txt"
    while read -r file; do
        cmp "conformance/protovalidate/proto/${file}" "${source}/proto/protovalidate-testing/${file}"
    done <"${cache}/schemas.txt"
fi

zig build protovalidate-executor -Drelease
log="$(mktemp)"
trap 'rm -f "${log}"' EXIT
status=0
"${runner}" --strict_message --strict_error \
    --expected_failures conformance/protovalidate_known_failing.yaml \
    zig-out/bin/protovalidate-executor >"${log}" 2>&1 || status=$?
cat "${log}"
if [ -n "${CONFORMANCE_REPORT:-}" ]; then
    {
        echo "## Conformance: protovalidate's harness v${version}"
        echo
        tail -n 1 "${log}" | sed 's/^/- /'
        echo
    } >>"${CONFORMANCE_REPORT}"
fi
exit "${status}"
