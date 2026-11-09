#!/bin/sh
# Every check of this repository, in the order a person runs them (CLAUDE.md, Commands). CI runs
# this script, so CI and a person run the same thing.
#
#   tools/ci.sh [report.md]                 every check, then exit 1 if any failed
#   tools/ci.sh --only <check> [report.md]  one check
#   tools/ci.sh --list                      the checks' names, as a JSON array
#
# The report gets a line for each check, and the tables of the checks that write one: interop
# across languages, the costs, the instruction counts and the conformance totals. CI publishes it as the
# job's summary, and the workflow runs each check of `--list` as a job of its own, so each shows
# apart in GitHub.
set -eu
cd "$(dirname "$0")/.."
checks="format commits test release bench costs go-bench perf generated interop interop-languages coverage conformance"
only=""
case "${1:-}" in
    --list)
        printf '['
        separator=""
        for check in ${checks}; do
            printf '%s"%s"' "${separator}" "${check}"
            separator=","
        done
        printf ']\n'
        exit 0
        ;;
    --only)
        only="$2"
        shift 2
        ;;
esac
report="${1:-/dev/null}"
# The tables a check writes go to the report too.
export INTEROP_REPORT="${report}"
export PERF_REPORT="${report}"
export CONFORMANCE_REPORT="${report}"
failed=""

# Writes a check's table to the report and passes: the check reports and never gates. A row
# marked "suspect" becomes a warning in GitHub's summary.
report_only() {
    printf '%s\n\n' "$2" | tee -a "${report}"
    if [ -n "${GITHUB_ACTIONS:-}" ] && printf '%s\n' "$2" | grep -q suspect; then
        echo "::warning title=$1::the $1 report holds a suspect row; its summary says which"
    fi
    return 0
}

# Runs one check by name.
check() {
    case "$1" in
        format) zig fmt --check build.zig build src tools examples bench conformance ;;
        # The commit messages of the change: origin/main..HEAD, or COMMIT_RANGE as CI sets it.
        commits) zig build install-commit-lint && zig-out/bin/commit_lint --range "${COMMIT_RANGE:-origin/main..HEAD}" ;;
        # The lint, every module's tests, the examples and the hook check.
        test) zig build test --summary all ;;
        release) zig build -Drelease ;;
        # The benchmark's smoke run: every operation on every message, a few short batches each.
        # The full run, and the comparison with Go, is tools/bench_check.sh.
        bench) zig build bench -- --quick ;;
        # The costs table of docs/performance.md, timed on this runner: the table goes to the report.
        # It reports and never gates, since a shared runner can time any row badly.
        costs) report_only costs "$(zig build costs 2>&1)" ;;
        # Go's runtime beside connect-zig's on the same inputs: the README's table comes from one
        # such run. The times report and never gate; the octets of both runtimes must match.
        go-bench) go_bench="$(tools/bench_check.sh 2>&1)" && go_status=0 || go_status=$?
            report_only go-bench "${go_bench}"
            return "${go_status}" ;;
        perf) tools/perf_check.sh ;;
        generated) tools/generate_check.sh ;;
        interop) tools/interop_check.sh ;;
        interop-languages) tools/interop_languages_check.sh ;;
        coverage) tools/coverage_check.sh ;;
        conformance) tools/conformance_check.sh ;;
        *)
            echo "no check named $1" >&2
            return 2
            ;;
    esac
}

run() {
    echo "== $1"
    if check "$1"; then
        echo "- $1: pass" >>"${report}"
    else
        echo "- $1: FAIL" >>"${report}"
        [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=$1::the check $1 failed; its log holds why"
        failed="${failed} $1"
    fi
}

if [ -n "${only}" ]; then
    echo "# connect-zig: ${only}" >>"${report}"
    run "${only}"
else
    echo "# connect-zig checks" >"${report}"
    for each in ${checks}; do run "${each}"; done
fi
[ -z "${failed}" ] || { echo "failed:${failed}" >&2; exit 1; }
