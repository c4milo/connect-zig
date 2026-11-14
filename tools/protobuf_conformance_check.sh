#!/bin/sh
# Runs Google's protobuf conformance suite against the program `zig build protobuf-testee` builds
# (decision 38). The runner sends each case's message in binary or in JSON, and checks what the
# program writes back in binary or in JSON, for proto3, proto2 and edition 2023. The cases of
# conformance/protobuf_known_failing.txt fail on purpose or do not pass yet, each for the reason
# the file gives; the runner fails when one of them passes, so a fix removes its lines.
#
# The runner comes prebuilt in the npm package protobuf-conformance, which Buf's
# protobuf-conformance repository names as the runner's home. The script fetches the package's
# tarball with curl, pinned by SHA-512, into a cache: it needs no npm and no node. The package
# holds a runner for x86-64 Linux and for macOS. PROTOBUF_CONFORMANCE names a runner to use
# instead.
set -eu
cd "$(dirname "$0")/.."
version="37.0.0-rc1"
# The registry's `dist.integrity` of the tarball, sha512-M83lj1qf..., as hexadecimal.
sha512="33cde58f5a9fa09d69679e7f099a7ea807b3dccf6e921630d247a79734b116934796644c5a28dac0e0ee1f1c19289304aeae079a42a86f8c68e2838dd09455ed"
# The edition the runner stops at: the plugin reads editions 2023 and 2024 (decision 23), and
# the package's test messages of a later edition are not generated here.
maximum_edition="2023"
cache="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/protobuf-conformance-${version}"

# The package's runner for this machine.
packaged_runner() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) echo "${cache}/package/bin/conformance_test_runner-linux-x64" ;;
        Darwin-*) echo "${cache}/package/bin/conformance_test_runner-darwin-x64" ;;
        *)
            echo "the package holds no runner for $(uname -s) on $(uname -m)" >&2
            return 1
            ;;
    esac
}

runner="${PROTOBUF_CONFORMANCE:-}"
if [ -z "${runner}" ]; then
    runner="$(packaged_runner)"
    if [ ! -x "${runner}" ]; then
        mkdir -p "${cache}"
        archive="${cache}/package.tgz"
        curl -sSfL -o "${archive}" "https://registry.npmjs.org/protobuf-conformance/-/protobuf-conformance-${version}.tgz"
        if command -v sha512sum >/dev/null 2>&1; then
            echo "${sha512}  ${archive}" | sha512sum -c -
        else
            echo "${sha512}  ${archive}" | shasum -a 512 -c -
        fi
        tar -xzf "${archive}" -C "${cache}"
        rm -f "${archive}"
    fi
    # The test protos this tree generates its code from are the package's own.
    for file in conformance/conformance.proto google/protobuf/test_messages_proto3.proto \
        google/protobuf/test_messages_proto2.proto google/protobuf/test_messages_edition2023.proto \
        google/protobuf/test_messages_proto3_editions.proto google/protobuf/test_messages_proto2_editions.proto; do
        cmp "conformance/proto/${file}" "${cache}/package/include/${file}"
    done
fi

zig build protobuf-testee -Drelease
log="$(mktemp)"
output="$(mktemp -d)"
trap 'rm -rf "${log}" "${output}"' EXIT
status=0
"${runner}" --maximum_edition "${maximum_edition}" --enforce_recommended \
    --failure_list conformance/protobuf_known_failing.txt --output_dir "${output}" \
    zig-out/bin/protobuf-testee >"${log}" 2>&1 || status=$?
cat "${log}"
if [ -n "${CONFORMANCE_REPORT:-}" ]; then
    {
        echo "## Conformance: Google's protobuf runner ${version}, up to edition ${maximum_edition}"
        echo
        grep '^CONFORMANCE SUITE' "${log}" | sed 's/^/- /'
        echo
    } >>"${CONFORMANCE_REPORT}"
fi
exit "${status}"
