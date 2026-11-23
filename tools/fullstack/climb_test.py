"""Tests of tools/fullstack/climb.py: how the reports read a server's rounds (tools/scripts_test.sh)."""

import contextlib
import io
import pathlib
import sys
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import climb


def step(rate, verdict="pass", round_number=1, spans=None, p99=5.0):
    """A step as `climb.read` gives it, with the spans a second ten thousand times the rate."""
    return {
        "rate": rate,
        "spans": rate * 10_000 if spans is None else spans,
        "verdict": verdict,
        "round": round_number,
        "p99": p99,
        "cpu": rate,
    }


def climb_of(round_number, passed, failed, verdict="p99"):
    """A round that passed each rate of `passed` and failed each rate of `failed`."""
    return [step(rate, "pass", round_number) for rate in passed] + [
        step(rate, verdict, round_number) for rate in failed
    ]


class ReadTest(unittest.TestCase):
    def test_reads_the_fields_of_each_step_and_the_peak_memory(self):
        lines = [
            "suite tls connect-zig TLS_AES_128_GCM_SHA256",
            "step tls connect-zig 1 356000 516 35600 1.20 3.50 0 pass 0.250 300 10500 2 1",
            "step cleartext connect-zig 2 712000 1032 71200 1.20 3.50 0 pass 0.250 300 10500 0 1",
            "step tls collector 1 300000 400 30000 9.00 150.00 4 refused -1 900 10000 0 2",
            "memory tls connect-zig 2048",
            "memory tls connect-zig 1024",
            "confirm tls connect-zig 1 3560000 516 35600 1.00 2.00 0 pass 0.200 3000 60000 0 0",
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as file:
            file.write("\n".join(lines) + "\n")
            file.flush()
            servers, steps, memory = climb.read(file.name, "tls", 100, 10)
            confirms = climb.read(file.name, "tls", 100, 60, "confirm")[1]
            self.assertEqual(climb.suites(file.name, "tls"), {"connect-zig": "TLS_AES_128_GCM_SHA256"})
            self.assertEqual(climb.suites(file.name, "cleartext"), {})
        self.assertEqual(servers, ["connect-zig", "collector"])
        self.assertEqual(memory, {"connect-zig": 2.0})
        first = steps["connect-zig"][0]
        self.assertEqual(len(steps["connect-zig"]), 1)
        self.assertEqual((first["rate"], first["taken"], first["calls"], first["spans"]), (1.0, 356000, 516.0, 35600.0))
        self.assertEqual((first["p50"], first["p99"], first["refused"], first["verdict"]), (1.2, 3.5, 0, "pass"))
        self.assertEqual((first["load"], first["reopened"], first["round"]), (0.25, 2, 1))
        # 300 ticks of 100 a second over the step's 10.5 s of wall time, which passes its 10 s.
        self.assertAlmostEqual(first["busy"], 300 / 100 / 10.5)
        # 3 s of CPU over 356,000 spans, in microseconds.
        self.assertAlmostEqual(first["cpu"], 300 * 1_000_000 / 100 / 356000)
        refused = steps["collector"][0]
        self.assertEqual((refused["verdict"], refused["refused"], refused["round"]), ("refused", 4, 2))
        # A step shorter than its nominal seconds counts over those seconds.
        self.assertAlmostEqual(refused["busy"], 900 / 100 / 10)
        self.assertEqual([item["rate"] for item in confirms["connect-zig"]], [1.0])


class HeldTest(unittest.TestCase):
    def test_holds_the_highest_step_passed_and_the_lowest_failed_above_it(self):
        steps = climb_of(1, [1, 2, 3, 2.5], [4, 3.5, 2.75])
        best, above, verdict = climb.held(steps)
        self.assertEqual((best["rate"], above["rate"], verdict), (3, 3.5, "p99"))

    def test_a_climb_with_no_failure_holds_a_floor(self):
        best, above, verdict = climb.held(climb_of(1, [1, 2], []))
        self.assertEqual((best["rate"], above, verdict), (2, None, "none: the last step passed"))

    def test_a_failure_on_the_load_bounds_nothing(self):
        best, above, verdict = climb.held(climb_of(1, [1, 2], [3], "load"))
        self.assertEqual((best["rate"], above, verdict), (2, None, "load"))

    def test_a_failure_below_the_step_held_is_no_bound(self):
        best, above, verdict = climb.held(climb_of(1, [1, 3], [2, 4], "rate"))
        self.assertEqual((best["rate"], above["rate"], verdict), (3, 4, "rate"))

    def test_a_climb_that_passed_nothing_holds_no_step(self):
        best, above, verdict = climb.held(climb_of(1, [], [1], "refused"))
        self.assertEqual((best, above["rate"], verdict), (None, 1, "refused"))


class SummaryTest(unittest.TestCase):
    def test_holds_the_median_round_and_the_range_of_the_rounds(self):
        steps = climb_of(1, [1, 2, 3], [4]) + climb_of(2, [1, 2, 5], [6]) + climb_of(3, [1, 4], [4.5])
        result, verdict = climb.summary(steps)
        # The rounds held 3, 5, and 4: the median round is the third.
        self.assertEqual(result["best"]["rate"], 4)
        self.assertEqual(result["best"]["round"], 3)
        self.assertEqual(result["above"]["rate"], 4.5)
        self.assertEqual(verdict, "p99")
        self.assertEqual((result["low"], result["high"]), (30_000, 50_000))
        self.assertEqual(result["spans"], {1: 30_000, 2: 50_000, 3: 40_000})
        # From the lowest step held to the highest step that failed above one.
        self.assertEqual((result["bottom"], result["top"]), (3, 6))

    def test_an_even_count_of_rounds_holds_the_lower_middle_one(self):
        steps = climb_of(1, [2], [3]) + climb_of(2, [8], [9]) + climb_of(3, [4], [5]) + climb_of(4, [6], [7])
        result, _ = climb.summary(steps)
        self.assertEqual(result["best"]["rate"], 4)

    def test_a_round_that_failed_no_step_leaves_the_interval_open(self):
        steps = climb_of(1, [2], [3]) + climb_of(2, [4], [])
        result, _ = climb.summary(steps)
        self.assertEqual((result["bottom"], result["top"]), (2, float("inf")))

    def test_a_round_that_held_no_step_counts_in_no_measure(self):
        steps = climb_of(1, [], [1], "refused") + climb_of(2, [2], [3]) + climb_of(3, [4], [5])
        result, _ = climb.summary(steps)
        self.assertEqual(result["spans"], {2: 20_000, 3: 40_000})
        self.assertEqual(result["best"]["rate"], 2)

    def test_no_round_held_gives_the_first_round_verdict(self):
        steps = climb_of(1, [], [1], "refused") + climb_of(2, [], [1], "p99")
        self.assertEqual(climb.summary(steps), (None, "refused"))
        self.assertEqual(climb.summary([]), (None, "no step"))


class CompareTest(unittest.TestCase):
    def test_round_ratios_divide_the_rounds_both_held(self):
        top = {"spans": {1: 300.0, 2: 200.0, 3: 100.0}}
        bottom = {"spans": {1: 100.0, 3: 50.0}}
        self.assertEqual(climb.round_ratios(top, bottom), [3.0, 2.0])

    def test_overlap_needs_each_interval_to_start_below_the_other_end(self):
        self.assertTrue(climb.overlap({"bottom": 1, "top": 3}, {"bottom": 2, "top": 4}))
        self.assertTrue(climb.overlap({"bottom": 2, "top": 4}, {"bottom": 1, "top": 3}))
        self.assertFalse(climb.overlap({"bottom": 1, "top": 2}, {"bottom": 3, "top": 4}))
        # Intervals that only touch do not overlap.
        self.assertFalse(climb.overlap({"bottom": 1, "top": 2}, {"bottom": 2, "top": 3}))
        self.assertFalse(climb.overlap({"bottom": 2, "top": 3}, {"bottom": 1, "top": 2}))

    def test_bound_reads_a_floor_on_either_side(self):
        failed = step(2, "p99")
        self.assertEqual(climb.bound(failed, failed), "")
        self.assertEqual(climb.bound(None, failed), "at least ")
        self.assertEqual(climb.bound(failed, None), "at most ")
        self.assertEqual(climb.bound(None, None), "about ")

    def test_resolution_is_the_gap_to_the_step_that_failed(self):
        self.assertAlmostEqual(climb.resolution(step(4), step(5, "p99")), 0.25)
        self.assertIsNone(climb.resolution(step(4), None))
        self.assertIsNone(climb.resolution(None, step(5, "p99")))

    def test_low_latency_takes_the_first_round_alone(self):
        steps = [
            step(1, p99=2),
            step(2, p99=9),
            step(3, p99=11),
            step(4, "p99", p99=200),
            step(5, round_number=2, p99=1),
        ]
        self.assertEqual(climb.low_latency(steps, 10)["rate"], 2)
        self.assertEqual(climb.low_latency(steps, 11)["rate"], 3)
        self.assertIsNone(climb.low_latency(steps, 1))

    def test_common_rate_is_the_highest_every_climb_passed(self):
        first = climb_of(1, [1, 2, 3], [4])
        second = climb_of(1, [1, 2], [3])
        self.assertEqual(climb.common_rate(first, second), 2)
        self.assertIsNone(climb.common_rate(climb_of(1, [], [1]), second))
        self.assertEqual(climb.at(first, 3)["rate"], 3)
        self.assertIsNone(climb.at(first, 7))

    def test_apart_needs_each_rate_outside_the_other_interval(self):
        self.assertTrue(climb.apart(step(2), step(3, "p99"), step(3), step(4, "p99")))
        self.assertFalse(climb.apart(step(2), step(4, "p99"), step(3), step(5, "p99")))
        self.assertFalse(climb.apart(step(2), None, step(3), step(4, "p99")))


class MainTest(unittest.TestCase):
    def test_prints_the_median_round_rate_for_production_sh(self):
        lines = [
            "step tls connect-zig 1 100 1 1 1 1 0 pass 0.1 1 10000 0 1",
            "step tls connect-zig 2 100 1 1 1 1 0 p99 0.1 1 10000 0 1",
            "step tls connect-zig 1.5 150 1 1.5 1 1 0 pass 0.1 1 10000 0 2",
            "step tls connect-zig 2 100 1 1 1 1 0 p99 0.1 1 10000 0 2",
            "step tls rotel 1 100 1 1 1 1 0 refused 0.1 1 10000 0 1",
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as file:
            file.write("\n".join(lines) + "\n")
            file.flush()
            for server, printed in (("connect-zig", "1\n"), ("rotel", ""), ("vector", "")):
                output = io.StringIO()
                with (
                    contextlib.redirect_stdout(output),
                    unittest.mock.patch.object(sys, "argv", ["climb.py", file.name, "tls", server]),
                ):
                    climb.main()
                self.assertEqual(output.getvalue(), printed)


if __name__ == "__main__":
    unittest.main()
