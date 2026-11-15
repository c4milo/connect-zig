#!/bin/sh
# Counts the lines of each library module that its tests run, with pepegrillo's coverage tool under
# kcov 43, and prints one line for each module and the total:
#
#   src/protobuf: note: [coverage] 91.2% of 1204 lines
#   zig-out/coverage: note: [coverage] total 88.4% of 3020 lines
#
# kcov runs on Linux. A host with kcov 43 runs `zig build line-coverage` itself. Another Linux host
# runs it in an ubuntu:26.04 container, which packages kcov 43, with this host's Zig, packages and
# caches; kcov needs ptrace there. The README's badge takes the total from CI's run of this check.
set -eu
cd "$(dirname "$0")/.."
if kcov --version 2>/dev/null | grep -q '^kcov 43'; then
    exec zig build line-coverage
fi
if [ "$(uname -s)" != Linux ]; then
    echo "kcov runs on Linux: run this check on Linux, or read CI's line-coverage job" >&2
    exit 2
fi
zig_dir="$(dirname "$(readlink -f "$(command -v zig)")")"
cache="${HOME}/.cache/zig"
mkdir -p "${cache}"
docker run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
    -v "$(pwd):$(pwd)" -w "$(pwd)" -v "${zig_dir}:${zig_dir}:ro" -v "${cache}:/root/.cache/zig" \
    ubuntu:26.04 sh -c "apt-get update -q >/dev/null && apt-get install -y -q kcov >/dev/null &&
        PATH=${zig_dir}:\$PATH zig build line-coverage"
