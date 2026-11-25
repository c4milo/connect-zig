"""Tests of tools/charts_release.sh (tools/scripts_test.sh): every chart a run drew is attached to
the tag's release, a tag with no release gets one first, and two charts of one name or no chart
at all attach nothing. A stub `gh` on the path writes each call it gets to a log."""

import os
import pathlib
import subprocess
import tempfile
import unittest

script = pathlib.Path(__file__).resolve().parent / "charts_release.sh"
# The stub: `release view` succeeds when RELEASE_EXISTS is set, and each call joins the log.
stub = """#!/bin/sh
echo "$*" >>"${GH_LOG}"
[ "$1 $2" != "release view" ] || [ -n "${RELEASE_EXISTS:-}" ]
"""


def release(work, files, exists):
    """Runs the script's functions over `files`, a chart's path under the run's folder to its
    text, and returns the finished process and the calls the stub logged."""
    work = pathlib.Path(work)
    for path, text in files.items():
        chart = work / "charts" / path
        chart.parent.mkdir(parents=True, exist_ok=True)
        chart.write_text(text)
    (work / "bin").mkdir()
    gh = work / "bin" / "gh"
    gh.write_text(stub)
    gh.chmod(0o755)
    log = work / "gh.log"
    environment = dict(os.environ, PATH=f"{work / 'bin'}:{os.environ['PATH']}", GH_LOG=str(log))
    if exists:
        environment["RELEASE_EXISTS"] = "1"
    body = f'. "{script}"\ncharts_gather "{work / "charts"}" "{work / "gathered"}" && charts_attach "{work / "gathered"}" v1.2.3\n'
    done = subprocess.run(["sh", "-c", body], env=environment, capture_output=True, text=True, check=False)
    calls = log.read_text().splitlines() if log.exists() else []
    return done, calls


class ChartsReleaseTest(unittest.TestCase):
    def test_attaches_every_chart_to_a_release_that_exists(self):
        with tempfile.TemporaryDirectory() as work:
            files = {"charts-fullstack-ARM64/fullstack-arm64.svg": "a", "charts-bench-compare-X64/speed-vs-go.svg": "b"}
            done, calls = release(work, files, exists=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(len(calls), 2)
            self.assertTrue(calls[1].startswith("release upload v1.2.3 "))
            self.assertIn("fullstack-arm64.svg", calls[1])
            self.assertIn("speed-vs-go.svg", calls[1])
            self.assertTrue(calls[1].endswith("--clobber"))

    def test_creates_the_release_a_tag_lacks(self):
        with tempfile.TemporaryDirectory() as work:
            done, calls = release(work, {"charts-x/speed-vs-go.svg": "b"}, exists=False)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(calls[1], "release create v1.2.3 --verify-tag --title v1.2.3 --generate-notes")
            self.assertTrue(calls[2].startswith("release upload v1.2.3 "))

    def test_two_charts_of_one_name_attach_nothing(self):
        with tempfile.TemporaryDirectory() as work:
            files = {"charts-a/speed-vs-go.svg": "a", "charts-b/speed-vs-go.svg": "b"}
            done, calls = release(work, files, exists=True)
            self.assertNotEqual(done.returncode, 0)
            self.assertIn("two charts are named speed-vs-go.svg", done.stderr)
            self.assertEqual(calls, [])

    def test_no_chart_attaches_nothing(self):
        with tempfile.TemporaryDirectory() as work:
            done, calls = release(work, {"charts-a/log.txt": "a"}, exists=True)
            self.assertNotEqual(done.returncode, 0)
            self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
