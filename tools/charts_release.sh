#!/bin/sh
# Attaches the charts a tag's benchmark jobs drew, and their files of values, to the tag's GitHub
# release, and adds what changed since the previous tag to its notes (decision 44 as amended on
# 2026-11-25). CI's job `charts` runs it after every benchmark job of the tag passed. It then
# writes the same files as the one commit of the branch `charts`, which the README and
# docs/benchmarks.md show each chart from: GitHub serves a release's files as downloads, which no
# page shows as an image (decision 44 as amended on 2026-11-26).
#
#   tools/charts_release.sh <charts> <tag>
#
# <charts> holds the run's charts, in folders of any depth, as `gh run download` writes them. A
# release the tag has none of is created, with notes GitHub writes; one that exists keeps its
# notes, and a file replaces the asset of its name. The text of tools/charts_compare.py replaces
# the notes' section of an earlier run, and goes to the run's summary too when
# GITHUB_STEP_SUMMARY names a file. It needs git with the tags and a remote `origin` it may push
# to, python3, and gh with GH_TOKEN and GH_REPO set.
set -eu

# The branch that holds the latest tag's charts, and the name its commit carries.
charts_branch_name=charts
charts_author_name="github-actions[bot]"
charts_author_email="41898182+github-actions[bot]@users.noreply.github.com"

# Copies each chart and each file of values under $1 into the folder $2, and fails when two share
# a name: the release would hold only one of them.
charts_gather() {
    mkdir -p "$2"
    found=0
    find "$1" -type f \( -name '*.svg' -o -name '*.json' \) | sort >"$2.list"
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
    gh release upload "$2" "$1"/* --clobber
}

# Writes every file of the folder $1 as the one commit of the branch `charts`, for the tag $2, and
# pushes it over the branch's last commit. Each tag's charts replace the last tag's, and the
# release keeps each tag's own. The commit is built in an index of its own, so the checkout and
# its HEAD stay as they were.
charts_branch() {
    index="$1.index"
    rm -f "${index}"
    GIT_INDEX_FILE="${index}" git read-tree --empty
    for chart in "$1"/*; do
        blob="$(git hash-object -w "${chart}")"
        GIT_INDEX_FILE="${index}" git update-index --add --cacheinfo "100644,${blob},${chart##*/}"
    done
    tree="$(GIT_INDEX_FILE="${index}" git write-tree)"
    rm -f "${index}"
    commit="$(git -c user.name="${charts_author_name}" -c user.email="${charts_author_email}" \
        commit-tree "${tree}" -m "chore: draw the charts of $2")"
    git push --force origin "${commit}:refs/heads/${charts_branch_name}"
}

# Replaces the section of the release's notes that tools/charts_compare.py wrote with the text in
# the file $1, for the tag $2, and adds the text to the run's summary.
charts_notes() {
    heading="$(python3 -c 'import sys; sys.path.insert(0, "tools"); import charts_compare; print(charts_compare.heading)')"
    gh release view "$2" --json body --jq .body | awk -v heading="${heading}" '$0 == heading { exit } { print }' >"$1.notes"
    cat "$1" >>"$1.notes"
    gh release edit "$2" --notes-file "$1.notes"
    rm -f "$1.notes"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat "$1" >>"${GITHUB_STEP_SUMMARY}"
    fi
}

# Writes the comparison of the charts' values in the folder $1 with the previous tag's, for the
# tag $2, into the file $3.
charts_compare() {
    previous="$1.previous"
    tools/charts_previous.sh "$2" "${previous}" >/dev/null
    python3 tools/charts_compare.py "${previous}" "$1" >"$3"
    rm -rf "${previous}"
}

main() {
    if [ "$#" -ne 2 ]; then
        echo "usage: tools/charts_release.sh <charts> <tag>" >&2
        exit 2
    fi
    cd "$(dirname "$0")/.."
    gathered="$(mktemp -d)"
    trap 'rm -rf "${gathered}" "${gathered}.list" "${gathered}.md" "${gathered}.index"' EXIT
    charts_gather "$1" "${gathered}"
    charts_attach "${gathered}" "$2"
    charts_branch "${gathered}" "$2"
    charts_compare "${gathered}" "$2" "${gathered}.md"
    charts_notes "${gathered}.md" "$2"
}

# A test sources this file for its functions, and then runs nothing.
case "${0##*/}" in
    charts_release.sh) main "$@" ;;
esac
