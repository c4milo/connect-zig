#!/bin/sh
# Regenerates tools/gen, bench/gen, conformance/gen, the code of validate.proto in
# src/protovalidate/gen, the code of protovalidate's conformance suite, the wide message of
# tools/wide and each example project's gen/ with `buf generate` and the plugin this tree
# builds, into a temporary directory, and fails when one differs from the committed code
# (design §8 step 6).
# With --write it rewrites them instead. It needs buf on the path, or BUF naming it.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
# The plugin alone: the rest of the build compiles the generated code this script rewrites.
zig build plugin
# Each output directory, and the template that writes it.
targets="tools/gen:tools/buf.gen.yaml bench/gen:bench/buf.gen.yaml conformance/gen:conformance/buf.gen.yaml src/protovalidate/gen:src/protovalidate/buf.gen.yaml conformance/protovalidate/gen:conformance/protovalidate/buf.gen.yaml tools/wide/gen:tools/wide/buf.gen.yaml"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
for target in ${targets}; do
    directory="${target%%:*}"
    "${buf}" generate --template "${target#*:}" --output "${scratch}"
    # --write replaces a directory only once buf wrote its new one, so a failure keeps the old.
    if [ "${1:-}" = "--write" ]; then
        rm -rf "${directory}"
        cp -R "${scratch}/${directory}" "${directory}"
        continue
    fi
    if ! diff -r "${directory}" "${scratch}/${directory}"; then
        echo "${directory} differs from what buf generate writes; run tools/generate_check.sh --write" >&2
        exit 1
    fi
    echo "${directory} matches buf generate"
done
# Each example project generates gen/ from its own proto/ (decision 41). Its buf.gen.yaml names
# the plugin in the project's zig-out, as a user's would, so the check gives buf the plugin this
# tree built in its place.
plugin="$(pwd)/zig-out/bin/protoc-gen-connect-zig"
template="{\"version\":\"v2\",\"plugins\":[{\"local\":\"${plugin}\",\"out\":\"gen\"}]}"
for project in examples/*/; do
    project="${project%/}"
    [ -d "${project}/proto" ] || continue
    rm -rf "${scratch:?}/project"
    mkdir -p "${scratch}/project"
    (cd "${project}" && "${buf}" generate --template "${template}" --output "${scratch}/project" proto)
    if [ "${1:-}" = "--write" ]; then
        rm -rf "${project}/gen"
        cp -R "${scratch}/project/gen" "${project}/gen"
        continue
    fi
    if ! diff -r "${project}/gen" "${scratch}/project/gen"; then
        echo "${project}/gen differs from what buf generate writes; run tools/generate_check.sh --write" >&2
        exit 1
    fi
    echo "${project}/gen matches buf generate"
done
