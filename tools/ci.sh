#!/bin/sh
# Every check of this repository, in the order a person runs them (CLAUDE.md, Commands). CI runs
# this script, so CI and a person run the same thing.
#
#   tools/ci.sh [report.md]                 every check, then exit 1 if any failed
#   tools/ci.sh --only <check> [report.md]  one check
#   tools/ci.sh --list                      the checks' names, as a JSON array
#
# The report gets a line for each check, and the tables of the checks that write one: interop
# across languages in both directions, the costs, the full stack, the instruction counts and the
# conformance totals. CI publishes it as the job's summary, and the workflow runs each check of
# `--list` as a job of its own, so each shows apart in GitHub.
set -eu
cd "$(dirname "$0")/.."
checks="format citations commits test release package bench costs bench-compare fullstack perf generated interop interop-languages interop-servers coverage line-coverage conformance protobuf-conformance protovalidate-conformance cel-differential cel-conformance compile-time validate-compare lean"
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

# Draws the README's charts of a check from its output (the first argument), into `charts`. Each
# chart names its run: GitHub's run number in CI, or "local". An arm64 runner's charts take the
# README's "-arm64" names. CI uploads `charts` with the run, and a person copies a chosen run's
# charts to docs/images (decision 44). A chart that does not draw is a warning: the check measured
# what it must.
charts="ci-charts"
draw_charts() {
    mkdir -p "${charts}"
    log="${charts}/$2.log"
    printf '%s\n' "$1" >"${log}"
    run_name="${GITHUB_RUN_NUMBER:-local}"
    commit="$(git rev-parse --short HEAD)"
    suffix=""
    [ "$(uname -m)" = aarch64 ] && suffix="-arm64"
    case "$2" in
        bench-compare) drawings="speed_chart:speed-vs-go call_chart:call-vs-go routes_chart:call-routes" ;;
        validate-compare) drawings="validate_chart:validate-vs-go" ;;
        fullstack) drawings="fullstack_chart:fullstack:tls fullstack_chart:fullstack-cleartext:cleartext" ;;
    esac
    for drawing in ${drawings}; do
        script="${drawing%%:*}" rest="${drawing#*:}"
        name="${rest%%:*}" transport=""
        [ "${rest}" = "${name}" ] || transport="${rest#*:}"
        out="${charts}/${name}${suffix}.svg"
        if ! python3 "tools/${script}.py" "${log}" "${run_name}" "${commit}" ${transport} "${out}" >&2; then
            echo "ci: tools/${script}.py drew no ${name}${suffix}.svg" >&2
            [ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning title=$2::tools/${script}.py drew no ${name}${suffix}.svg"
        fi
    done
}

# Runs one check by name.
check() {
    case "$1" in
        format) zig fmt --check build.zig build src tools examples bench conformance ;;
        # The specifications of docs/specs as their publishers wrote them, and each citation of
        # one in the code (docs/specs/README.md).
        citations) tools/citations_check.sh ;;
        # The commit messages of the change: origin/main..HEAD, or COMMIT_RANGE as CI sets it.
        commits) zig build install-commit-lint && zig-out/bin/commit_lint --range "${COMMIT_RANGE:-origin/main..HEAD}" ;;
        # The lint, every module's tests, the examples and the hook check.
        test) zig build test --summary all ;;
        release) zig build -Drelease ;;
        # A project that fetches connect-zig as a package builds against it.
        package) tools/package_check.sh ;;
        # The benchmark's smoke run: every operation on every message, a few short batches each.
        # The full run, and the comparison with Go, is tools/bench_check.sh.
        bench) zig build bench -- --quick ;;
        # The costs table of docs/performance.md, timed on this runner: the table goes to the report.
        # It reports and never gates, since a shared runner can time any row badly.
        costs) report_only costs "$(zig build costs 2>&1)" ;;
        # Go's runtime and Rust's Buffa beside connect-zig's on the same inputs: the README's
        # table comes from one such run. The times report and never gate; the octets of every
        # runtime must match.
        bench-compare) compare="$(tools/bench_check.sh 2>&1)" && compare_status=0 || compare_status=$?
            report_only bench-compare "${compare}"
            draw_charts "${compare}" bench-compare
            return "${compare_status}" ;;
        # Whole servers over TLS and h2, connect-zig's OTLP sink beside OpenTelemetry's Collector
        # (decision 44). The times report and never gate; every span must arrive.
        fullstack) full="$(tools/fullstack_check.sh)" && full_status=0 || full_status=$?
            report_only fullstack "${full}"
            draw_charts "${full}" fullstack
            return "${full_status}" ;;
        perf) tools/perf_check.sh ;;
        generated) tools/generate_check.sh ;;
        interop) tools/interop_check.sh ;;
        interop-languages) tools/interop_languages_check.sh ;;
        interop-servers) tools/interop_servers_check.sh ;;
        coverage) tools/coverage_check.sh ;;
        # Each module's share of lines that its tests run, under kcov: the README's badge takes the
        # total from this report.
        line-coverage) lines="$(tools/line_coverage_check.sh 2>&1)" && lines_status=0 || lines_status=$?
            echo "${lines}"
            report_only line-coverage "$(echo "${lines}" | grep '\[coverage\]')"
            return "${lines_status}" ;;
        conformance) tools/conformance_check.sh ;;
        # Google's protobuf conformance suite, in binary and JSON (decision 38).
        protobuf-conformance) tools/protobuf_conformance_check.sh ;;
        # protovalidate's conformance harness, against the rules the library checks (decision 47).
        protovalidate-conformance) tools/protovalidate_conformance_check.sh ;;
        # Random CEL rules over random messages: this library's verdicts against those of
        # protovalidate-go, which runs cel-go (decision 47).
        cel-differential) tools/cel_differential_check.sh 1 2 3 ;;
        # cel-spec's conformance suite, against the code a rule's expression compiles into.
        cel-conformance) tools/cel_conformance_check.sh ;;
        # What a schema's CEL rules cost the compiler, against bench/compile_time.txt.
        compile-time) tools/compile_time_check.sh ;;
        # protovalidate's implementations in Zig, Go, Node.js and Rust on one schema: the times
        # report and never gate; every verdict must match (docs/benchmarks.md, "Validation").
        validate-compare) validate="$(tools/validate_compare_check.sh 2>&1)" && validate_status=0 || validate_status=$?
            report_only validate-compare "${validate}"
            draw_charts "${validate}" validate-compare
            return "${validate_status}" ;;
        # The Lean model of the CEL syntax, and the vectors a unit test replays against the Zig
        # grammar (spec/README.md).
        lean) tools/lean_check.sh ;;
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
