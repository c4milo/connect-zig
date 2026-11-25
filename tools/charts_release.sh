#!/bin/sh
# Attaches the charts a tag's benchmark jobs drew to the tag's GitHub release (decision 44 as
# amended on 2026-11-25). CI's job `charts` runs it after every benchmark job of the tag passed.
# The README and docs/benchmarks.md show each chart from the latest release.
#
#   tools/charts_release.sh <charts> <tag>
#
# <charts> holds the run's charts, in folders of any depth, as `gh run download` writes them. A
# release the tag has none of is created, with notes GitHub writes; one that exists keeps its
# notes, and a chart replaces the asset of its name. It needs gh, with GH_TOKEN and GH_REPO set.
set -eu

# Copies each chart under $1 into the folder $2, and fails when two charts share a name: the
# release would hold only one of them.
charts_gather() {
    mkdir -p "$2"
    found=0
    find "$1" -type f -name '*.svg' | sort >"$2.list"
    while IFS= read -r chart; do
        name="${chart##*/}"
        if [ -e "$2/${name}" ]; then
            echo "charts_release.sh: two charts are named ${name}" >&2
            return 1
        fi
        cp "${chart}" "$2/${name}"
        found=$((found + 1))
    done <"$2.list"
    rm -f "$2.list"
    if [ "${found}" -eq 0 ]; then
        echo "charts_release.sh: the run drew no chart" >&2
        return 1
    fi
}

# Attaches every chart of the folder $1 to the release of the tag $2, and creates the release
# first when the tag has none.
charts_attach() {
    if ! gh release view "$2" >/dev/null 2>&1; then
        gh release create "$2" --verify-tag --title "$2" --generate-notes
    fi
    gh release upload "$2" "$1"/*.svg --clobber
}

main() {
    if [ "$#" -ne 2 ]; then
        echo "usage: tools/charts_release.sh <charts> <tag>" >&2
        exit 2
    fi
    gathered="$(mktemp -d)"
    trap 'rm -rf "${gathered}" "${gathered}.list"' EXIT
    charts_gather "$1" "${gathered}"
    charts_attach "${gathered}" "$2"
}

# A test sources this file for its functions, and then runs nothing.
case "${0##*/}" in
    charts_release.sh) main "$@" ;;
esac
