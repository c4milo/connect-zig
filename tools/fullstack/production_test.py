"""Tests of the climbs of tools/fullstack/production.sh (tools/scripts_test.sh): the first round's
steps and halvings, and a later round's search near the rate held before. A stub of
`production_step` passes each rate at or below a limit and fails each rate above it, so the rate a
round holds must sit just under the limit: at or below it, and above it by less than the last gap
the round halved."""

import os
import pathlib
import subprocess
import tempfile
import unittest

root = pathlib.Path(__file__).resolve().parents[2]
# The stub's step: a line of the server, the rate, and the verdict, as production_climb's callers
# read the lines, and no server, load, or wait.
stub = """
production_step() {
    step_rate="$2"
    verdict="$(awk -v rate="$2" -v limit="${stub_limit}" 'BEGIN { print (rate <= limit) ? "pass" : "p99" }')"
    echo "step ${transport} $1 $2 ${verdict} ${round}"
}
production_begin() { passed="" failed="" verdict=pass; }
production_end() { :; }
rest_seconds=0
"""


def climb(rounds, limit, held=None):
    """The step lines of `rounds` rounds of connect-zig, each against the stub's limit, and the
    rate the climb saved for the later rounds. `held` is a rate an earlier round held."""
    with tempfile.TemporaryDirectory() as work:
        if held is not None:
            pathlib.Path(work, "held-tls-connect-zig").write_text(f"{held}\n")
        script = f". tools/fullstack/servers.sh\n. tools/fullstack/production.sh\n{stub}\ntransport=tls\n"
        script += "".join(f"production_climb connect-zig {number}\n" for number in range(1, rounds + 1))
        done = subprocess.run(
            ["sh", "-c", script],
            cwd=root,
            env=dict(os.environ, work=work, stub_limit=str(limit)),
            capture_output=True,
            text=True,
            check=True,
        )
        saved = pathlib.Path(work, "held-tls-connect-zig").read_text().strip()
    steps = [line.split() for line in done.stdout.splitlines()]
    return [(float(fields[3]), fields[4], int(fields[5])) for fields in steps], float(saved)


def bracket(steps, round_number):
    """The highest rate a round passed and the lowest rate above it that failed."""
    rates = [(rate, verdict) for rate, verdict, number in steps if number == round_number]
    passed = max(rate for rate, verdict in rates if verdict == "pass")
    failed = min((rate for rate, verdict in rates if verdict != "pass" and rate > passed), default=None)
    return passed, failed


class FirstRoundTest(unittest.TestCase):
    def test_steps_up_until_one_fails_then_halves_the_gap(self):
        steps, saved = climb(1, 5.3)
        rates = [rate for rate, _, _ in steps]
        # The steps of production_steps, up to 6, the first that fails.
        self.assertEqual(rates[:13], [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 5, 5.5, 5.25, 5.375])
        self.assertEqual(len(steps), 9 + 5)
        passed, failed = bracket(steps, 1)
        self.assertEqual((passed, failed, saved), (5.25, 5.3125, 5.25))
        # Five halvings of the gap of 2 between 4 and 6.
        self.assertLessEqual(failed - passed, 2 / 2**5)

    def test_a_climb_that_never_fails_holds_its_highest_step(self):
        steps, saved = climb(1, 100)
        self.assertEqual([verdict for _, verdict, _ in steps], ["pass"] * 18)
        self.assertEqual(saved, 48)


class SearchTest(unittest.TestCase):
    def test_a_later_round_brackets_the_limit_near_the_rate_held_before(self):
        steps, _ = climb(1, 4.6, held=5.25)
        rates = [rate for rate, _, _ in steps]
        # A warm step at the highest step at or below half of 5.25, then 80% and 120% of it.
        self.assertEqual(rates[:3], [2, 4.2, 6.3])
        passed, failed = bracket(steps, 1)
        self.assertLessEqual(passed, 4.6)
        self.assertGreater(failed, 4.6)
        # Four halvings of the gap between 80% and 120% of 5.25.
        self.assertLessEqual(failed - passed, 5.25 * 0.4 / 2**4)
        self.assertEqual(len(steps), 3 + 4)

    def test_a_search_moves_down_while_its_low_step_fails(self):
        steps, _ = climb(1, 5, held=10)
        rates = [round(rate, 3) for rate, _, _ in steps]
        self.assertEqual(rates[:5], [4, 8, 6.4, 5.12, 4.096])
        passed, failed = bracket(steps, 1)
        self.assertLessEqual(passed, 5)
        self.assertGreater(failed, 5)
        # Four halvings of the gap between the step that passed and the step above it.
        self.assertAlmostEqual(failed - passed, (5.12 - 4.096) / 2**4)

    def test_a_search_whose_high_step_never_fails_holds_a_floor(self):
        steps, _ = climb(1, 100, held=1)
        rates = [round(rate, 4) for rate, _, _ in steps]
        # No warm step: no step of production_steps lies at or below half of 1 but 0.5.
        self.assertEqual(rates, [0.5, 0.8, 1.2, 1.44, 1.728, 2.0736])
        self.assertEqual(bracket(steps, 1), (2.0736, None))

    def test_rounds_after_the_first_search_near_the_first_rate(self):
        steps, saved = climb(3, 5.3)
        self.assertEqual(saved, 5.25)
        for number in (2, 3):
            passed, failed = bracket(steps, number)
            self.assertLessEqual(passed, 5.3)
            self.assertGreater(failed, 5.3)
            # The round starts at 80% of the first round's 5.25, not from the lowest step.
            self.assertEqual([rate for rate, _, round_number in steps if round_number == number][1], 4.2)


if __name__ == "__main__":
    unittest.main()
