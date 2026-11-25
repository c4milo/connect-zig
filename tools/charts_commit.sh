#!/bin/sh
# Commits the charts a tag's benchmark jobs drew to docs/images on main (decision 44 as amended on
# 2026-11-25). CI's job `charts` runs it after every benchmark job of the tag passed.
#
#   tools/charts_commit.sh <charts> <tag>
#
# <charts> holds the run's charts, in folders of any depth, as `gh run download` writes them. Each
# chart that docs/images holds is replaced by the run's chart of the same name, and no other chart
# joins. A chart the run did not draw keeps its old file, and the script names it. With no change
# the script commits nothing. A push that main refused because it moved is tried again on the new
# main, up to `push_tries` times. It needs git, and a checkout of main that may push.
set -eu

# The tries of a push, each on main as the remote holds it then.
push_tries=4
images="docs/images"

# Replaces each chart of `images` with the chart of the same name under $1, and prints each name it
# found no chart for.
charts_copy() {
    for image in "${images}"/*.svg; do
        name="${image##*/}"
        drawn="$(find "$1" -type f -name "${name}" | head -n 1)"
        if [ -z "${drawn}" ]; then
            echo "charts_commit.sh: the run drew no ${name}; it keeps its old file" >&2
            continue
        fi
        cp "${drawn}" "${image}"
    done
}

# Commits the charts as CI's bot, naming the tag $1. Returns 1 when no chart changed.
charts_record() {
    git add -- "${images}"
    if git diff --cached --quiet; then
        echo "charts_commit.sh: no chart changed" >&2
        return 1
    fi
    git -c user.name="github-actions[bot]" \
        -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit -q -m "docs: draw the benchmark charts of $1"
}

# Pushes the commit to main, and puts it on main again each time the push is refused.
charts_push() {
    try=1
    while [ "${try}" -le "${push_tries}" ]; do
        git push -q origin HEAD:main && return 0
        git fetch -q origin main
        git rebase -q FETCH_HEAD
        try=$((try + 1))
    done
    echo "charts_commit.sh: main refused ${push_tries} pushes" >&2
    return 1
}

main() {
    if [ "$#" -ne 2 ]; then
        echo "usage: tools/charts_commit.sh <charts> <tag>" >&2
        exit 2
    fi
    cd "$(dirname "$0")/.."
    charts_copy "$1"
    charts_record "$2" || exit 0
    charts_push
}

# A test sources this file for its functions, and then runs nothing.
case "${0##*/}" in
    charts_commit.sh) main "$@" ;;
esac
