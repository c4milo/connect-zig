#!/bin/sh
# Downloads the charts' files of values of the tag before <tag> into <folder>, and prints that tag
# (decision 44 as amended on 2026-11-25). On a tag, each benchmark job draws its charts with them,
# and the job `charts` compares with them.
#
#   tools/charts_previous.sh <tag> <folder>
#
# The previous tag is the newest tag named v* that <tag>'s parent reaches. With no such tag, or a
# release that holds no file of values, the folder stays empty and the charts mark nothing. It
# needs git with the tags, and gh with GH_TOKEN and GH_REPO set.
set -eu

# The newest v* tag that the parent of $1 reaches, or nothing.
previous_tag() {
    git describe --tags --abbrev=0 --match 'v*' "$1^" 2>/dev/null || true
}

# Downloads the files of values of the release of the tag $1 into the folder $2.
values_of() {
    mkdir -p "$2"
    if ! gh release download "$1" --pattern '*.json' --dir "$2" --clobber >/dev/null 2>&1; then
        echo "charts_previous.sh: the release of $1 holds no file of values" >&2
    fi
}

main() {
    if [ "$#" -ne 2 ]; then
        echo "usage: tools/charts_previous.sh <tag> <folder>" >&2
        exit 2
    fi
    mkdir -p "$2"
    previous="$(previous_tag "$1")"
    if [ -z "${previous}" ]; then
        echo "charts_previous.sh: no tag comes before $1" >&2
        exit 0
    fi
    values_of "${previous}" "$2"
    echo "${previous}"
}

# A test sources this file for its functions, and then runs nothing.
case "${0##*/}" in
    charts_previous.sh) main "$@" ;;
esac
