#!/bin/sh
# Compares the protobuf runtime with Go's, through buf convert, on every case in
# examples/testdata/<set>, where each set names a message: coverage.v1.Everything holds each
# proto3 scalar in each cardinality, every map key type, oneofs, enums, recursion and each
# well-known type; editions.v1.Everything holds edition 2023's features; legacy.v1.Everything
# holds proto2 and its groups. For each case it checks:
#
# 1. Zig reads the JSON and writes binary that Go reads back as the same message;
# 2. Zig reads Go's binary and writes JSON that equals Go's JSON;
# 3. Zig reads Go's binary and writes it back as binary that Go reads as the same message;
# 4. Zig reads the JSON Go writes;
# 5. Zig's binary equals Go's byte for byte, but where Go sorts a map's keys, which Zig keeps in
#    the order they came, and where Go's NaN carries a payload bit Zig's does not;
# 6. for coverage, Zig reads Go's binary with an older schema, coverage.v1.Partial, and writes
#    back the same message: each field Partial does not know passes through.
#
# Checks 7 and 8, at the end, take Python's upb as the reference for the binary cases.
#
# JSON texts are compared after jq sorts their keys, since a map's members have no order. It
# needs buf on the path, or BUF naming it, jq, and python3 with venv, which installs the pinned
# protobuf of tools/upb_requirements.txt into a cache unless UPB_PYTHON names a Python that has it.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
zig build
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/coverage" "${work}/editions" "${work}/legacy"
converter=zig-out/bin/coverage
failures=0
go_convert() {
    "${buf}" convert examples/proto --type "${set}.v1.Everything" --from "$1" --to "$2"
}
same() {
    jq -S . "$2" >"${work}/want.json"
    jq -S . "$3" >"${work}/got.json"
    if cmp -s "${work}/want.json" "${work}/got.json"; then
        echo "ok: $1"
    else
        echo "FAIL: $1" >&2
        diff "${work}/want.json" "${work}/got.json" >&2 || true
        failures=$((failures + 1))
    fi
}
for case in examples/testdata/coverage/*.json examples/testdata/editions/*.json examples/testdata/legacy/*.json; do
    set="$(basename "$(dirname "${case}")")"
    name="${set}/$(basename "${case}" .json)"
    go_convert "${case}#format=json" "${work}/${name}.go.binpb#format=binpb"
    go_convert "${case}#format=json" "${work}/${name}.go.json#format=json"
    "${converter}" "${set}" json-to-binary <"${case}" >"${work}/${name}.zig.binpb"
    go_convert "${work}/${name}.zig.binpb#format=binpb" "${work}/${name}.zig-binary.json#format=json"
    same "${name}: Zig's binary of the JSON" "${work}/${name}.go.json" "${work}/${name}.zig-binary.json"
    "${converter}" "${set}" binary-to-json <"${work}/${name}.go.binpb" >"${work}/${name}.zig.json"
    same "${name}: Zig's JSON of Go's binary" "${work}/${name}.go.json" "${work}/${name}.zig.json"
    "${converter}" "${set}" binary-to-binary <"${work}/${name}.go.binpb" >"${work}/${name}.again.binpb"
    go_convert "${work}/${name}.again.binpb#format=binpb" "${work}/${name}.again.json#format=json"
    same "${name}: Go's binary through Zig" "${work}/${name}.go.json" "${work}/${name}.again.json"
    "${converter}" "${set}" json-to-binary <"${work}/${name}.go.json" >"${work}/${name}.from-go.binpb"
    go_convert "${work}/${name}.from-go.binpb#format=binpb" "${work}/${name}.from-go.json#format=json"
    same "${name}: Zig reads Go's JSON" "${work}/${name}.go.json" "${work}/${name}.from-go.json"
    if [ "${set}" = coverage ]; then
        # 6. Read with a schema that knows only the scalars, Go's binary keeps every other field.
        "${converter}" "${set}" through-partial <"${work}/${name}.go.binpb" >"${work}/${name}.partial.binpb"
        go_convert "${work}/${name}.partial.binpb#format=binpb" "${work}/${name}.partial.json#format=json"
        same "${name}: unknown fields pass through" "${work}/${name}.go.json" "${work}/${name}.partial.json"
    fi
    if cmp -s "${work}/${name}.go.binpb" "${work}/${name}.zig.binpb"; then
        echo "ok: ${name}: the same bytes as Go"
    else
        case "${name}" in
            coverage/maps | coverage/well_known | coverage/extremes | editions/full) echo "ok: ${name}: the same length as Go, in another map order or NaN" ;;
            *)
                echo "FAIL: ${name}: bytes differ from Go's" >&2
                failures=$((failures + 1))
                ;;
        esac
        [ "$(wc -c <"${work}/${name}.go.binpb")" -eq "$(wc -c <"${work}/${name}.zig.binpb")" ] || {
            echo "FAIL: ${name}: length differs from Go's" >&2
            failures=$((failures + 1))
        }
    fi
done

# The binary cases hold what JSON cannot: numbers a closed enum does not name, and strings that
# are not UTF-8 where a field's utf8_validation is NONE. Go keeps such numbers in their fields
# (protobuf.dev, "Enum Behavior"), so upb, Python's runtime, is the reference here. For each:
# 7. upb writes the same octets from Zig's binary as from the case;
# 8. Zig's JSON equals upb's, or, where Go refuses to write JSON, Zig refuses too.
python="${UPB_PYTHON:-}"
if [ -z "${python}" ]; then
    venv="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/upb-$(sha256sum tools/upb_requirements.txt | cut -c1-12)"
    if [ ! -x "${venv}/bin/python" ]; then
        python3 -m venv "${venv}"
        "${venv}/bin/pip" install --quiet --disable-pip-version-check --require-hashes -r tools/upb_requirements.txt
    fi
    python="${venv}/bin/python"
fi
"${buf}" build examples/proto --as-file-descriptor-set -o "${work}/descriptors.binpb"
upb() {
    "${python}" -I tools/upb_reference.py "$@"
}
for case in examples/testdata/legacy/*.binpb examples/testdata/editions/*.binpb; do
    set="$(basename "$(dirname "${case}")")"
    name="${set}/$(basename "${case}" .binpb)"
    type="${set}.v1.Everything"
    "${converter}" "${set}" binary-to-binary <"${case}" >"${work}/${name}.zig.binpb"
    if upb binary "${work}/descriptors.binpb" "${type}" "${case}" "${work}/${name}.zig.binpb"; then
        echo "ok: ${name}: upb reads Zig's binary as the case"
    else
        echo "FAIL: ${name}: upb reads Zig's binary as another message" >&2
        failures=$((failures + 1))
    fi
    if go_convert "${case}#format=binpb" "${work}/${name}.go.json#format=json" 2>/dev/null; then
        "${converter}" "${set}" binary-to-json <"${case}" >"${work}/${name}.zig.json"
        if upb json "${work}/descriptors.binpb" "${type}" "${case}" "${work}/${name}.zig.json"; then
            echo "ok: ${name}: Zig's JSON equals upb's"
        else
            echo "FAIL: ${name}: Zig's JSON differs from upb's" >&2
            failures=$((failures + 1))
        fi
    elif "${converter}" "${set}" binary-to-json <"${case}" >/dev/null 2>&1; then
        echo "FAIL: ${name}: Zig wrote JSON that Go refuses to write" >&2
        failures=$((failures + 1))
    else
        echo "ok: ${name}: Zig, as Go, refuses to write it as JSON"
    fi
done
[ "${failures}" -eq 0 ] || exit 1
echo "every coverage case matches Go, and every binary case matches upb"
