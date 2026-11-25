"""Tests of `tools/ci.sh --matrix` (tools/scripts_test.sh): a push runs every check but the
benchmarks, a tag the benchmarks alone, each on x86-64, and the arm64 checks on arm64 too
(decision 44 as amended on 2026-11-25)."""

import json
import pathlib
import subprocess
import unittest

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


if __name__ == "__main__":
    unittest.main()
