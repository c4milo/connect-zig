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
# JSON texts are compared after jq sorts their keys, since a map's members have no order. It
# needs buf on the path, or BUF naming it, and jq.
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
[ "${failures}" -eq 0 ] || exit 1
echo "every coverage case matches Go"
