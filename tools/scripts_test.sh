#!/bin/sh
# Runs the unit tests of the Python and shell scripts of bench/ and tools/ with Python's unittest
# (docs/testing.md). A test is a tracked file named <script>_test.py beside its script; a test of
# a shell script sources it in sh. tools/scripts_check.sh runs this script last.
#
#   tools/scripts_test.sh [test.py...]
#
# With no test named, it runs every one. It needs python3, sh, awk, and git, and no package.
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -eq 0 ]; then
    tests="$(git ls-files 'bench/*_test.py' 'tools/*_test.py')"
    if [ -z "${tests}" ]; then
        echo "scripts_test.sh: no tracked file named *_test.py" >&2
        exit 1
    fi
    # The list holds one path a line: it splits at newlines alone, and no path expands as a pattern.
    set -f
    IFS='
'
    # shellcheck disable=SC2086 # the list holds one path a line, one argument each
    set -- ${tests}
fi
# Python leaves no cache of a module it imports in the tree.
python3 -B -m unittest "$@"
