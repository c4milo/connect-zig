"""Tests of tools/fullstack/peak_report.py: the peak report's table and comparisons, from round
lines the tests write (tools/scripts_test.sh)."""

import contextlib
import io
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import peak_report

# Each server's rounds at the export of 16 spans: the calls a second, p50 and p99 in microseconds,
# the CPU ticks over the 1,000 calls, at 100 ticks a second, and the peak memory in KiB.
rounds = {
    "connect-zig": [(100, 3000, 9000, 10, 1024), (300, 1000, 7000, 30, 3072), (200, 2000, 8000, 20, 2048)],
    "connect-zig-generic": [(180, 2000, 8000, 25, 2048)],
    "connect-zig-validate": [(150, 2000, 8000, 30, 2048)],
    "connect-go": [(50, 2000, 8000, 40, 2048)],
    "connect-go-memory": [(40, 2000, 8000, 50, 2048)],
}


def report_text(rows):
    with tempfile.TemporaryDirectory() as work:
        with open(os.path.join(work, "peak-results"), "w") as file:
            for server, measures in rows.items():
                file.writelines(
                    f"16 {server} {rate} {p50} {p99} {cpu} 1000 {peak}\n" for rate, p50, p99, cpu, peak in measures
                )
        # gRPC's prefix of 5 octets, then a message of 1,000.
        with open(os.path.join(work, "export-16.grpc"), "wb") as file:
            file.write(bytes(1005))
        arguments = [work, "100", "h2load 1", "otelcol 2", "vector 3", "go 4", "rust 5", "abc1234", "placement"]
        arguments += ["3", "16", "4", "suite", "75MiB"]
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            peak_report.write(peak_report.parse(arguments), "test machine")
    return output.getvalue().split("\n")


class PeakReportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lines = report_text(rounds)

    def test_each_cell_is_the_median_of_its_measure_alone(self):
        # The rates 100, 300, and 200, and the p50s of 3, 1, and 2 ms: each median comes from its
        # own measure, not from the round of the median rate.
        self.assertIn("| 16 spans, 1,000 B | connect-zig | 200 | 2.00 | 8.00 | 200.0 | 2.0 |", self.lines)

    def test_a_server_with_no_round_reads_absent(self):
        self.assertIn("| 16 spans, 1,000 B | Collector | absent | | | | |", self.lines)
        self.assertIn("| 16 spans, 1,000 B | connect-go, 75 MiB | 40 | 2.00 | 8.00 | 500.0 | 2.0 |", self.lines)

    def test_the_comparisons_name_each_ratio(self):
        self.assertIn(
            "- 16 spans: connect-zig answers 4.00 times connect-go's calls a second, and spends 0.50 times its CPU "
            "time a call.",
            self.lines,
        )
        self.assertIn(
            "- 16 spans: connect-zig built for the generic CPU answers 90.0% of the calls a second of its build for "
            "this CPU, and spends +25% CPU time a call.",
            self.lines,
        )
        self.assertIn(
            "- 16 spans: connect-go with 75 MiB and its collector off below it answers 80.0% of connect-go's calls a "
            "second, and spends +25% CPU time a call; connect-zig answers 5.00 times its calls a second.",
            self.lines,
        )
        self.assertIn(
            "- 16 spans: connect-zig + protovalidate answers 75.0% of connect-zig's calls a second, and spends "
            "100.0 µs more CPU time a call.",
            self.lines,
        )
        # A variant of a server is no server of its own to compare connect-zig with.
        self.assertFalse(any("times connect-go, 75 MiB's" in text for text in self.lines))

    def test_a_report_without_connect_zig_compares_nothing(self):
        lines = report_text({server: rows for server, rows in rounds.items() if server != "connect-zig"})
        self.assertFalse(any(text.startswith("- 16 spans: connect-zig") for text in lines))
        self.assertIn("| 16 spans, 1,000 B | connect-zig | absent | | | | |", lines)

    def test_the_footer_names_the_load_and_the_limit(self):
        self.assertIn("Machine: test machine.", self.lines)
        self.assertIn("Load: h2load 1, 16 connections of 4 streams each, suite; placement.", self.lines)
        self.assertIn(
            "GOMEMLIMIT=75MiB, about what connect-zig's sink holds, so its collector runs only as its heap nears that.",
            self.lines,
        )
        self.assertEqual(self.lines[-2], "Rounds: 3.")


if __name__ == "__main__":
    unittest.main()
