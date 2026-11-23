"""Tests of tools/fullstack/production_report.py: the production report's tables, from result
lines the tests write (tools/scripts_test.sh)."""

import contextlib
import io
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import production_report

# The classes of tools/fullstack/production.sh: 35,600 spans at a rate of 1.
classes = ["16:361", "128:129", "512:26"]


def line(server, rate, verdict, round_number, kind="step", reopened=0):
    """A result line: the spans a second are a thousand times the rate, and the CPU 1,000 ticks."""
    spans = rate * 1000
    return (
        f"{kind} tls {server} {rate:g} {int(spans * 10)} {rate * 516:.0f} {spans:.0f} 1.00 5.00 0 {verdict} "
        f"0.500 1000 10000 {reopened} {round_number}"
    )


def round_lines(server, round_number, passed, failed, verdict="p99", reopened=0):
    return [line(server, rate, "pass", round_number, reopened=reopened) for rate in passed] + [
        line(server, rate, verdict, round_number) for rate in failed
    ]


def results(confirm=True):
    lines = ["suite tls connect-zig TLS_AES_128_GCM_SHA256"]
    lines += round_lines("connect-zig", 1, [1, 2, 3], [4], reopened=2)
    lines += round_lines("connect-zig", 2, [2.4, 3.6], [4.32])
    lines += round_lines("connect-zig", 3, [2.4, 3.3], [3.5])
    lines += round_lines("connect-zig-validate", 1, [1, 2], [3])
    lines += round_lines("connect-zig-validate", 2, [1.6, 2.2], [2.4])
    lines += round_lines("connect-zig-validate", 3, [1.6, 2.1], [2.3])
    # The Collector holds no step: a call is refused at the first.
    lines += round_lines("collector", 1, [], [1], "refused")
    # Vector runs one round, which ends short of the rate.
    lines += round_lines("vector", 1, [1], [2], "rate")
    lines += ["memory tls connect-zig 2048", "memory tls vector 1024"]
    if confirm:
        lines += [line("connect-zig", 1.65, "pass", 0, "confirm"), line("connect-zig", 3.3, "pass", 0, "confirm")]
    return "\n".join(lines) + "\n"


def report_text(text, transport="tls"):
    with tempfile.NamedTemporaryFile("w", suffix=".txt") as file:
        file.write(text)
        file.flush()
        arguments = [file.name, transport, "100", "load", "otelcol 0.1", "vector 0.2", "rotel 0.3", "go", "rust"]
        arguments += ["abc1234", "placement", "10", "32", "100", "3", "60"] + classes
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            production_report.write(production_report.parse(arguments), "test machine")
    return output.getvalue()


class ProductionReportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = report_text(results())
        cls.lines = cls.text.split("\n")

    def row(self, name):
        return next(text for text in self.lines if text.startswith(f"| {name} |"))

    def test_the_table_holds_the_median_round_and_the_range(self):
        cells = [cell.strip() for cell in self.row("connect-zig").strip("|").split("|")]
        # The rounds held 3,000, 3,600, and 3,300 spans a second: the median round is the third,
        # whose step above failed at 3.5, 6.1% above its 3.3.
        self.assertEqual(cells[1:4], ["3,300", "3,000–3,600", "+6.1%"])
        # The first round held 3,000 spans a second with p99 under 10 ms.
        self.assertEqual(cells[7:12], ["100%", "50%", "303.03", "2", "3,000"])
        self.assertEqual(cells[12], "p99 past 100 ms")

    def test_a_server_that_held_no_step_reads_none(self):
        self.assertEqual(self.row("Collector"), "| Collector | none | | | | | | | | | | | a call refused |")

    def test_one_round_gives_a_range_of_one_rate(self):
        cells = [cell.strip() for cell in self.row("Vector").strip("|").split("|")]
        self.assertEqual(cells[1:4], ["1,000", "1,000–1,000", "+100.0%"])
        self.assertEqual(cells[12], "spans short of the rate")

    def test_the_comparisons_take_the_rounds_both_held(self):
        self.assertIn("- connect-zig closed connections: the load opened 6 again over its rounds.", self.lines)
        self.assertIn(
            "- connect-zig holds 3.30 times Vector's spans a second on one core, 3.00 to 3.00 times round by round.",
            self.lines,
        )
        validation = next(text for text in self.lines if text.startswith("- connect-zig + protovalidate"))
        self.assertTrue(
            validation.startswith(
                "- connect-zig + protovalidate holds 64% of connect-zig's spans a second, 61% to 67% round by round. "
                "At 71,200 spans a second, which both held,"
            ),
            validation,
        )
        self.assertIn(
            "- At 64 cores, the spans a second each server carries for each of the 33,000 servers: "
            "connect-zig 6, connect-zig + protovalidate 4, Vector 2.",
            self.lines,
        )

    def test_the_confirm_table_takes_the_step_at_the_median_rate(self):
        self.assertIn("| connect-zig | 117,480 | 3,300 | 5.00 | 100% | held |", self.lines)
        self.assertNotIn("Each server then ran", report_text(results(confirm=False)))

    def test_the_first_round_table_marks_each_failed_step(self):
        self.assertIn(
            "| 1 | 35,600 | 5.00 | 100% | 5.00 | 100% | 5.00 (refused) | 100% | 5.00 | 100% |",
            self.lines,
        )
        self.assertIn("| 4 | 142,400 | 5.00 (p99) | 100% |  |  |  |  |  |  |", self.lines)

    def test_the_footer_names_the_machine_and_each_suite(self):
        self.assertIn("Machine: test machine.", self.lines)
        self.assertIn(
            "TLS: the load offers AES-128-GCM alone, in TLS 1.3 and in TLS 1.2, and each server's connections ran "
            "connect-zig TLS_AES_128_GCM_SHA256.",
            self.lines,
        )
        self.assertTrue(self.lines[-2].startswith("Servers: connect-zig abc1234 in ReleaseSafe"))
        self.assertIn("otelcol 0.1, GOMAXPROCS=1", self.lines[-2])

    def test_a_report_with_no_connect_zig_compares_nothing(self):
        text = "\n".join(item for item in results().split("\n") if " connect-zig " not in item)
        lines = report_text(text).split("\n")
        self.assertFalse(any(item.startswith("- connect-zig holds") for item in lines))
        self.assertFalse(any(item.startswith("- At 64 cores") for item in lines))


if __name__ == "__main__":
    unittest.main()
