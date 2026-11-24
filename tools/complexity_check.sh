#!/bin/sh
# Holds each function of the hand-written Python, Go, Rust, and JavaScript of bench/ and tools/ to
# cognitive complexity 15, the limit `zig build lint` holds their Zig to (decision 49):
#
# - Python: complexipy, which scores each function, and tools/complexity/top_level.py, which
#   refuses control flow at a module's top level, where complexipy scores nothing;
# - Go: gocognit;
# - Rust: rust-code-analysis, through tools/complexity/rust_findings.py;
# - JavaScript: the cognitive-complexity rule of eslint's sonarjs plugin.
#
#   tools/complexity_check.sh
#
# No tool scores a shell script, so the shell scripts have ShellCheck alone
# (tools/scripts_check.sh). It skips each gen/ folder. tools/complexity pins each tool:
# complexipy 9.0.0 by the SHA-256 of each wheel in requirements.txt, gocognit v1.3.0 in go.mod and
# go.sum, eslint 9.39.5 with eslint-plugin-sonarjs 4.2.2 in package-lock.json, and
# rust-code-analysis-cli 0.0.25 below. It needs python3 with venv, go, cargo, and node with npm.
# package.json lifts each minimatch to 11.0.9, past GHSA-g3hv-75wg-m249, a denial of service by a
# pattern: eslint-plugin-sonarjs asks for ^10.2.6. The override names no package, so npm 10 and
# npm 11 write one lockfile from it. Under an override of the plugin alone, npm 11 lifted more
# of eslint's packages than npm 10 did, and its `npm ci` refused the lockfile npm 10 wrote.
set -eu
cd "$(dirname "$0")/.."
root="$(pwd)"
# CLAUDE.md, Conventions: the cognitive-complexity threshold. Never raised.
limit=15
cache="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
status=0

# The tracked files of bench/ and tools/ that match the pattern, but those of a gen/ folder: one
# path a line.
files_of() {
    git ls-files "bench/$1" "tools/$1" | grep -v -e '^gen/' -e '/gen/' || true
}

# Python: complexipy in a virtual environment of its own, which pip fills from requirements.txt
# with each hash checked, once for each Python version.
python_check() {
    version="$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
    venv="${cache}/complexipy-9.0.0-python${version}"
    if [ ! -x "${venv}/bin/complexipy" ]; then
        rm -rf "${venv}"
        python3 -m venv "${venv}"
        "${venv}/bin/pip" install --quiet --require-hashes --only-binary :all: \
            -r tools/complexity/requirements.txt
    fi
    files="$(files_of '*.py')"
    echo "Python: $(printf '%s\n' "${files}" | wc -l | tr -d ' ') files"
    # It prints each function over the limit, between lines of its own. Its cache goes in the
    # temporary folder, and it reads no snapshot, which would let a function that passed the
    # limit before stay over it.
    # shellcheck disable=SC2086 # the list holds one path a line, one argument each
    if ! found="$("${venv}/bin/complexipy" --failed --color no --snapshot-ignore \
        --cache-dir "${work}/complexipy" --max-complexity-allowed "${limit}" ${files})"; then
        printf '%s\n' "${found}"
        status=1
    fi
    # shellcheck disable=SC2086 # the list holds one path a line, one argument each
    python3 tools/complexity/top_level.py ${files} || status=1
}

# Go: gocognit, which tools/complexity's go.mod names as a tool, so its go.sum checks the module.
go_check() {
    files="$(files_of '*.go')"
    echo "Go: $(printf '%s\n' "${files}" | wc -l | tr -d ' ') files"
    # The paths are absolute, since the tool runs in its module's folder.
    # shellcheck disable=SC2046 # one path a line, one argument each
    found="$(cd tools/complexity && go tool gocognit -over "${limit}" \
        $(printf '%s\n' "${files}" | sed "s|^|${root}/|") 2>/dev/null)" || true
    if [ -n "${found}" ]; then
        printf '%s\n' "${found}"
        status=1
    fi
}

# Rust: rust-code-analysis, which reads the source with no build and scores by SonarSource's
# method, as the other tools do. Cargo builds it once into the cache, from crates.io at the
# version below, with the lockfile the crate ships.
rust_check() {
    install="${cache}/rust-code-analysis-0.0.25"
    if [ ! -x "${install}/bin/rust-code-analysis-cli" ]; then
        cargo install --quiet --locked --version 0.0.25 --root "${install}" rust-code-analysis-cli
    fi
    files="$(files_of '*.rs')"
    echo "Rust: $(printf '%s\n' "${files}" | wc -l | tr -d ' ') files"
    # shellcheck disable=SC2046 # one option or path a line, one argument each
    "${install}/bin/rust-code-analysis-cli" --metrics --output-format json \
        $(printf '%s\n' "${files}" | sed 's/^/--paths\n/') >"${work}/rust.json"
    python3 tools/complexity/rust_findings.py "${limit}" "${work}/rust.json" || status=1
}

# JavaScript: eslint, which npm installs from package-lock.json into the cache, once for each lock.
javascript_check() {
    lock="$(sha256sum tools/complexity/package-lock.json | cut -c1-16)"
    install="${cache}/eslint-${lock}"
    if [ ! -x "${install}/node_modules/.bin/eslint" ]; then
        rm -rf "${install}"
        mkdir -p "${install}"
        cp tools/complexity/package.json tools/complexity/package-lock.json "${install}/"
        # npm says nothing when it installs, and says why when it refuses the lockfile.
        if ! output="$(cd "${install}" && npm ci --no-audit --no-fund 2>&1)"; then
            printf '%s\n' "${output}"
            exit 1
        fi
    fi
    # The configuration imports the plugin, which node finds beside the configuration.
    cp tools/complexity/eslint.config.mjs "${install}/"
    files="$(files_of '*.js')"
    echo "JavaScript: $(printf '%s\n' "${files}" | wc -l | tr -d ' ') files"
    # shellcheck disable=SC2086 # the list holds one path a line, one argument each
    COMPLEXITY_LIMIT="${limit}" "${install}/node_modules/.bin/eslint" --no-warn-ignored \
        --config "${install}/eslint.config.mjs" ${files} || status=1
}

# The lists split at newlines alone, and no path expands as a pattern.
set -f
IFS='
'
python_check
go_check
rust_check
javascript_check
if [ "${status}" -eq 0 ]; then
    echo "every function at cognitive complexity ${limit} or less"
fi
exit "${status}"
