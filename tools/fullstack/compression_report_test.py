"""Tests of tools/fullstack/compression_report.py: the compression report's tables and shares, from
a work folder the tests write (tools/scripts_test.sh)."""

import contextlib
import io
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import compression_report

classes = ["16:361", "128:129", "512:26"]


def line(server, rate, verdict, round_number, cpu):
    """A climb's line: the spans a second are a thousand times the rate."""
    spans = rate * 1000
    return (
        f"step tls {server} {rate:g} {int(spans * 10)} {rate * 516:.0f} {spans:.0f} 1.00 5.00 0 {verdict} "
        f"0.500 {cpu} 10000 0 {round_number}"
    )


def climb_lines(server, round_number, passed, failed, cpu=1000):
    return [line(server, rate, "pass", round_number, cpu) for rate in passed] + [
        line(server, rate, "p99", round_number, cpu) for rate in failed
    ]


climbs = {
    "identity": climb_lines("connect-zig", 1, [1, 2, 4], [5])
    + climb_lines("connect-zig", 2, [3.2, 4.8], [5.76])
    + climb_lines("connect-zig", 3, [3.2, 4.4], [4.6])
    + climb_lines("connect-go", 1, [1], [2])
    + climb_lines("connect-rust", 1, [1, 2], [3])
    + ["suite tls connect-zig TLS_AES_128_GCM_SHA256"],
    # gzip holds three quarters of connect-zig's rate in two rounds, and costs 20% more CPU a span.
    "gzip": climb_lines("connect-zig", 1, [1, 2, 3], [4], 1200)
    + climb_lines("connect-zig", 2, [2.4, 3.6], [4.32], 1200)
    + climb_lines("connect-zig", 3, [2.4, 3.4], [3.5], 1200)
    + climb_lines("connect-go", 1, [1], [2]),
}
# Each round of the peak at 512 spans: the calls a second, by coding and server.
peak = {
    "identity": {"connect-zig": [1000, 1100, 900], "connect-go": [100, 100, 100]},
    "gzip": {"connect-zig": [800, 850, 750], "connect-go": [95, 105, 100]},
}


def report_text():
    with tempfile.TemporaryDirectory() as work:
        for coding, lines in climbs.items():
            with open(os.path.join(work, f"compression-climb-{coding}"), "w") as file:
                file.write("\n".join(lines) + "\n")
        for coding, servers in peak.items():
            with open(os.path.join(work, f"compression-peak-{coding}"), "w") as file:
                for server, rates in servers.items():
                    file.writelines(f"512 {server} {rate} 1000 2000 50 1000 4096\n" for rate in rates)
        with open(os.path.join(work, "compression-octets"), "w") as file:
            file.write("16 identity 6400 6400\n16 gzip 6400 1280\n")
        arguments = [work, "tls", "100", "h2load 1", "load 2", "go 3", "rust 4", "abc1234", "placement", "3"]
        arguments += ["10", "32", "100", "3", "TLS_AES_128_GCM_SHA256", "identity gzip"] + classes
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            compression_report.write(compression_report.parse(arguments), "test machine")
    return output.getvalue().split("\n")


class CompressionReportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lines = report_text()

    def test_the_octets_give_each_coding_its_ratio(self):
        self.assertIn("| 16 spans | 6,400 | 1,280 (5.0×) |", self.lines)

    def test_a_coding_share_is_the_median_of_the_rounds(self):
        # gzip held 3,000, 3,600, and 3,400 against 4,000, 4,800, and 4,400: 75%, 75%, and 77%. The
        # median round is the third, whose step above failed at 3.5, 2.9% above its 3.4.
        self.assertIn(
            "| connect-zig | gzip | 3,400 | 3,000–3,600 | 75% | 75–77% | +2.9% | 5.00 | p99 past 100 ms |", self.lines
        )
        self.assertIn(
            "| connect-zig | uncompressed | 4,400 | 4,000–4,800 | 100% |  | +4.5% | 5.00 | p99 past 100 ms |",
            self.lines,
        )

    def test_a_coding_with_no_climb_reads_no_step(self):
        self.assertIn("| connect-rust | gzip | no step | | | | | | no step |", self.lines)

    def test_the_lines_tell_a_share_apart_from_100_percent(self):
        self.assertIn(
            "- connect-zig in gzip holds 75% of its uncompressed spans a second, 75% to 77% round by round.", self.lines
        )
        self.assertIn(
            "- connect-go in gzip and uncompressed hold rates the rounds cannot tell apart (100%, 100% to 100% round by "
            "round).",
            self.lines,
        )

    def test_the_cpu_compares_at_the_highest_rate_every_first_round_held(self):
        # Both first rounds held 2: 71,200 spans a second, at 500 µs a span uncompressed and 600 in gzip.
        self.assertIn(
            "- connect-zig at 71,200 spans a second, which every coding's first round held, spends µs of CPU a span: "
            "uncompressed 500.00, gzip 600.00 (+20%).",
            self.lines,
        )

    def test_the_peak_gives_the_median_and_marks_ranges_that_overlap(self):
        self.assertIn("| 512 spans | connect-zig | gzip | 800 | 750–850 | 2.00 | 500.0 |", self.lines)
        self.assertIn("| 512 spans | connect-rust | uncompressed | absent | | | |", self.lines)
        self.assertIn("- 512 spans, connect-zig: calls a second as a share of uncompressed: gzip 80%.", self.lines)
        self.assertIn(
            "- 512 spans, connect-go: calls a second as a share of uncompressed: gzip 100% (ranges overlap).",
            self.lines,
        )

    def test_the_footer_names_each_suite(self):
        self.assertIn(
            "TLS: both loads offer AES-128-GCM alone, TLS_AES_128_GCM_SHA256 in TLS 1.3, and each receiver's "
            "connections in the climb ran connect-zig TLS_AES_128_GCM_SHA256.",
            self.lines,
        )


if __name__ == "__main__":
    unittest.main()
