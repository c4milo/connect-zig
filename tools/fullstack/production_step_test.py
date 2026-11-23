"""Tests of tools/fullstack/production_step.py: one step's line and its verdict, from a work folder
the tests write (tools/scripts_test.sh)."""

import contextlib
import io
import os
import pathlib
import sys
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import production_step

# Two classes: 10 connections of exports of 16 spans, and 2 of 512. At a rate of 1 export a
# connection a second, a step of 10 s sends 100 calls of 16 spans and 20 of 512.
classes = [(16, 10), (512, 2)]
seconds, limit_ms, rate = 10.0, 100.0, 1.0


def write_step(folder, latencies_ms, statuses=None):
    """The CSV files of a step: each class's calls take the latencies in turn."""
    for spans, connections in classes:
        calls = int(rate * connections * seconds)
        with open(os.path.join(folder, f"step-{spans}.csv"), "w") as file:
            file.write("scheduled,request-duration,status\n")
            for index in range(calls):
                status = statuses(spans, index) if statuses else "200"
                file.write(f"{index / calls:.3f},{latencies_ms[index % len(latencies_ms)] / 1000:.6f},{status}\n")


class StepTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.work = self.folder.name

    def tearDown(self):
        self.folder.cleanup()

    def line(self, load_before="-", load_after="-"):
        return production_step.step_line(self.work, seconds, limit_ms, rate, load_before, load_after, classes)

    def test_a_step_that_holds_its_rate_passes(self):
        write_step(self.work, [1.0, 2.0, 3.0, 4.0])
        # 100 calls of 16 spans and 20 of 512: 11,840 spans, 12 calls and 1,184 spans a second.
        self.assertEqual(self.line(), "11840 12 1184 2.00 4.00 0 pass -1.000")

    def test_p99_takes_the_nearest_rank(self):
        # 120 calls: the 99th percentile is the 119th smallest latency.
        latencies = [1.0] * 118 + [50.0, 150.0]
        write_step(self.work, latencies[:100])
        _, _, _, read_latencies, _ = production_step.read(self.work, classes, rate)
        self.assertEqual(production_step.rank(sorted(latencies), 0.99), 50.0)
        self.assertEqual(production_step.rank([1.0, 2.0, 3.0, 4.0], 0.5), 2.0)
        self.assertEqual(production_step.rank([], 0.5), float("inf"))
        self.assertEqual(len(read_latencies), 120)

    def test_a_p99_past_the_limit_fails(self):
        write_step(self.work, [1.0] * 9 + [150.0])
        self.assertEqual(self.line().split()[6], "p99")
        write_step(self.work, [100.0])
        self.assertEqual(self.line().split()[6], "pass")

    def test_a_refused_call_fails_whatever_its_latency(self):
        write_step(self.work, [1.0], lambda spans, index: "503" if spans == 512 and index == 3 else "200")
        fields = self.line().split()
        self.assertEqual((fields[0], fields[5], fields[6]), (str(100 * 16 + 19 * 512), "1", "refused"))

    def test_spans_short_of_the_rate_fail(self):
        write_step(self.work, [1.0])
        # The spans of the step over its seconds fall short of 95% of what twice the rate sends.
        line = production_step.step_line(self.work, seconds, limit_ms, rate * 2, "-", "-", classes)
        self.assertEqual(line.split()[6], "rate")
        # At 1/0.95 of the rate, the spans reach 95% of it exactly.
        line = production_step.step_line(self.work, seconds, limit_ms, rate / 0.95, "-", "-", classes)
        self.assertEqual(line.split()[6], "pass")

    def test_a_failure_while_the_load_cores_were_full_names_the_load(self):
        write_step(self.work, [150.0])
        # 900 of 1,000 ticks busy: 90%, the threshold.
        self.assertEqual(self.line("100:1000", "1000:2000").split()[6:], ["load", "0.900"])
        # 899 of 1,000 ticks busy.
        self.assertEqual(self.line("100:1000", "999:2000").split()[6:], ["p99", "0.899"])
        # A refused call stays a refusal, however busy the load was.
        write_step(self.work, [1.0], lambda spans, index: "503")
        self.assertEqual(self.line("100:1000", "1000:2000").split()[6], "refused")

    def test_load_busy_reads_the_ticks_of_the_load_cores(self):
        self.assertEqual(production_step.load_busy("-", "-"), -1)
        self.assertEqual(production_step.load_busy("10:100", "-"), -1)
        self.assertAlmostEqual(production_step.load_busy("10:100", "60:200"), 0.5)
        # No tick passed: the share divides by 1 at least.
        self.assertEqual(production_step.load_busy("10:100", "10:100"), 0)

    def test_main_prints_the_line_from_its_arguments(self):
        write_step(self.work, [1.0, 2.0, 3.0, 4.0])
        arguments = ["production_step.py", self.work, "10", "100", "1", "-", "-", "16:10", "512:2"]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), unittest.mock.patch.object(sys, "argv", arguments):
            production_step.main()
        self.assertEqual(output.getvalue(), "11840 12 1184 2.00 4.00 0 pass -1.000\n")


if __name__ == "__main__":
    unittest.main()
