"""Tests of `tools/ci.sh --matrix` (tools/scripts_test.sh): a push runs every check but the
benchmarks, a tag the benchmarks alone, each on x86-64, and the arm64 checks on arm64 too
(decision 44 as amended on 2026-11-25)."""

import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import speed_chart_test

script = pathlib.Path(__file__).resolve().parent / "ci.sh"
benchmarks = {
    "bench-compare",
    "fullstack",
    "fullstack-peak",
    "fullstack-cleartext",
    "fullstack-compression",
    "fullstack-compression-cleartext",
    "validate-compare",
}


def matrix(event):
    done = subprocess.run([str(script), "--matrix", event], capture_output=True, text=True, check=True)
    return [(job["check"], job["runner"]) for job in json.loads(done.stdout)]


def every_check():
    done = subprocess.run([str(script), "--list"], capture_output=True, text=True, check=True)
    return json.loads(done.stdout)


class MatrixTest(unittest.TestCase):
    def test_push_and_tag_split_the_checks(self):
        push = {check for check, _ in matrix("push")}
        tag = {check for check, _ in matrix("tag")}
        self.assertEqual(tag, benchmarks)
        self.assertEqual(push | tag, set(every_check()))
        self.assertFalse(push & tag)

    def test_arm64_jobs_follow_their_x86_64_job(self):
        jobs = matrix("push") + matrix("tag")
        arm = {check for check, runner in jobs if runner == "ubuntu-26.04-arm"}
        self.assertEqual(arm, {"test", "bench-compare", "fullstack", "fullstack-compression", "validate-compare"})
        for check in arm:
            self.assertIn((check, "ubuntu-26.04"), jobs)

    def test_refuses_another_event(self):
        done = subprocess.run([str(script), "--matrix", "nightly"], check=False, capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)


def draw_charts(table, charts, previous=None):
    """Runs ci.sh's `draw_charts` for bench-compare over a table, into the folder `charts`, with
    CHARTS_PREVIOUS naming `previous`. The function is lifted out of the script, which runs its
    checks when sourced."""
    text = script.read_text()
    function = re.search(r'^charts="ci-charts"\n.*?^}\n', text, re.DOTALL | re.MULTILINE).group(0)
    body = f'{function}charts="{charts}"\ndraw_charts "$1" bench-compare\n'
    environment = dict(os.environ)
    environment.pop("GITHUB_ACTIONS", None)
    if previous:
        environment["CHARTS_PREVIOUS"] = str(previous)
    # The table holds no routed call, so two of the three charts draw nothing, and their warnings
    # are no failure of the test.
    command = ["sh", "-c", body, "sh", table]
    subprocess.run(command, check=False, cwd=script.parent.parent, env=environment, capture_output=True)


class DrawChartsTest(unittest.TestCase):
    def test_a_chart_reads_the_previous_tag_values_the_folder_holds(self):
        table = speed_chart_test.table_text(speed_chart_test.speed_rows())
        with tempfile.TemporaryDirectory() as work:
            first, second = pathlib.Path(work, "first"), pathlib.Path(work, "second")
            draw_charts(table, first)
            self.assertNotIn('class="was"', (first / "speed-vs-go.svg").read_text())
            draw_charts(table, second, previous=first)
            self.assertIn('class="was"', (second / "speed-vs-go.svg").read_text())
            self.assertTrue((second / "speed-vs-go.json").exists())


if __name__ == "__main__":
    unittest.main()
