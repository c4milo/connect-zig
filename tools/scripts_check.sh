#!/bin/sh
# Lints the Python and shell scripts of this tree (docs/testing.md): ruff's lint and
# its format check under ruff.toml, and shellcheck under .shellcheckrc.
#
#   tools/scripts_check.sh
#
# It reads each tracked Python file and each tracked shell script: a file named *.sh, and a file
# of .githooks/ or tools/ with no extension whose first line names a shell. It skips the code that
# other projects or a generator wrote: docs/specs, conformance/, zig-pkg/, and each gen/ folder.
# `ruff format` rewrites the Python files that the format check refuses.
#
# It downloads ruff 0.17.6 and ShellCheck 0.11.0 into a cache, each checked against a pinned
# SHA-256, for x86-64 and arm64 Linux, unless RUFF and SHELLCHECK name installed ones. It then
# needs curl, tar, xz, and git.
set -eu
cd "$(dirname "$0")/.."
ruff_version="0.17.6"
shellcheck_version="0.11.0"
# The SHA-256 of each download: ruff's from the .sha256 file beside each archive in its release,
# and ShellCheck's computed from its archives, since its release publishes no checksum. ruff's
# musl builds link no libc, so one runs on any Linux.
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        ruff_triple=x86_64-unknown-linux-musl
        ruff_sha256=3c8d5a4264558df8b1587ce32409b658069b6a1ef5bfe4d279431eb1db62a183
        shellcheck_arch=x86_64
        shellcheck_sha256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
        ;;
    Linux-aarch64)
        ruff_triple=aarch64-unknown-linux-musl
        ruff_sha256=dc96feed20df78c9498106cd2483e710a4db8b00b13a75954b2a37bc9f61e65c
        shellcheck_arch=aarch64
        shellcheck_sha256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
        ;;
    *)
        ruff_triple=""
        shellcheck_arch=""
        ;;
esac

# Downloads a release archive into the cache once, checked by its SHA-256, and prints the path of
# the program that the fourth argument names in it. The fifth argument is tar's option for the
# archive's compression.
fetch() {
    dir="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/$1"
    if [ ! -x "${dir}/program" ]; then
        mkdir -p "${dir}"
        curl -sSfL --retry 3 -o "${dir}/download" "$2"
        echo "$3  ${dir}/download" | sha256sum -c - >&2
        tar "-x$5f" "${dir}/download" -C "${dir}" "$4"
        mv "${dir}/$4" "${dir}/program"
        rm -f "${dir}/download"
        chmod 0755 "${dir}/program"
    fi
    echo "${dir}/program"
}

ruff="${RUFF:-}"
if [ -z "${ruff}" ]; then
    if [ -z "${ruff_triple}" ]; then
        echo "scripts_check.sh: no pinned ruff for $(uname -s) on $(uname -m); RUFF names one" >&2
        exit 1
    fi
    ruff="$(fetch "ruff-${ruff_version}-${ruff_triple}" \
        "https://github.com/astral-sh/ruff/releases/download/${ruff_version}/ruff-${ruff_triple}.tar.gz" \
        "${ruff_sha256}" "ruff-${ruff_triple}/ruff" z)"
fi
shellcheck="${SHELLCHECK:-}"
if [ -z "${shellcheck}" ]; then
    if [ -z "${shellcheck_arch}" ]; then
        echo "scripts_check.sh: no pinned ShellCheck for $(uname -s) on $(uname -m); SHELLCHECK names one" >&2
        exit 1
    fi
    release="https://github.com/koalaman/shellcheck/releases/download/v${shellcheck_version}"
    shellcheck="$(fetch "shellcheck-${shellcheck_version}-${shellcheck_arch}" \
        "${release}/shellcheck-v${shellcheck_version}.linux.${shellcheck_arch}.tar.xz" \
        "${shellcheck_sha256}" "shellcheck-v${shellcheck_version}/shellcheck" J)"
fi
"${ruff}" --version
"${shellcheck}" --version | sed -n 's/^version: /shellcheck /p'

# Whether a path is code that another project or a generator wrote.
excluded() {
    case "$1" in
        docs/specs/* | conformance/* | zig-pkg/* | gen/* | */gen/*) return 0 ;;
    esac
    return 1
}
# One path a line: the tracked Python files, and the tracked shell scripts.
python_files="$(git ls-files '*.py' | while IFS= read -r path; do excluded "${path}" || echo "${path}"; done)"
shell_files="$(git ls-files '*.sh' .githooks tools | while IFS= read -r path; do
    excluded "${path}" && continue
    case "${path}" in
        *.sh) echo "${path}" ;;
        *)
            # A file with no extension is a shell script when its first line names a shell.
            case "${path##*/}" in *.*) continue ;; esac
            if head -n 1 "${path}" | grep -q -E '^#!.*[/ ](ba|da)?sh( |$)'; then echo "${path}"; fi
            ;;
    esac
done)"
count() {
    if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}
echo "$(count "${python_files}") Python files and $(count "${shell_files}") shell scripts"

# The lists split at newlines alone, and no path expands as a pattern.
set -f
IFS='
'
status=0
# shellcheck disable=SC2086 # the list holds one path a line, one argument each
"${ruff}" check --no-cache ${python_files} || status=1
# shellcheck disable=SC2086 # the list holds one path a line, one argument each
"${ruff}" format --check --no-cache ${python_files} || status=1
# shellcheck disable=SC2086 # the list holds one path a line, one argument each
if "${shellcheck}" ${shell_files}; then
    echo "shellcheck: no finding"
else
    status=1
fi
exit "${status}"
