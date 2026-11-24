"""Tests of tools/compression_chart.py: its reading of a compression report, each bar's share, and
the whiskers' ends (tools/scripts_test.sh)."""

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import chart_text
import compression_chart

# The marks a label of the chart can carry.
marks = ("≥", "slots full")

climb_header = "| server | coding | spans/s held | range | share | share range | resolution | p99 ms | the next step |"
peak_header = "| export | server | coding | calls/s | calls/s range | p99 ms | CPU µs a call |"
log_lines = [
    "## Full stack, compression over TLS: connect-zig, connect-go and connect-rust",
    climb_header,
    "|---|---|--:|--:|--:|--:|--:|--:|---|",
    "| connect-zig | uncompressed | 1,000,000 | 900,000–1,200,000 | 100% |  | +2.0% | 5.00 | p99 past 100 ms |",
    "| connect-zig | gzip | 750,000 | 700,000–800,000 | 75% | 70–80% | +2.0% | 5.00 | p99 past 100 ms |",
    "| connect-zig | zstd | 900,000 | 900,000–900,000 | 90% | 90–90% |  | 5.00 | none: the last step passed |",
    "| connect-go | uncompressed | no step | | | | | | a call refused |",
    "| connect-rust | uncompressed | 100,000 | 100,000–100,000 | 100% |  | +5.0% | 5.00 | a call refused |",
    peak_header,
    "|---|---|---|--:|--:|--:|--:|",
    "| 16 spans | connect-zig | uncompressed | 9,000 | 8,000–10,000 | 1.00 | 1.0 |",
    "| 512 spans | connect-zig | uncompressed | 1,000 | 900–1,100 | 1.00 | 1.0 |",
    "| 512 spans | connect-zig | gzip | 800 | 750–850 | 1.00 | 1.0 |",
    "| 512 spans | connect-go | uncompressed | absent | | | |",
    "Machine: aarch64, Neoverse-N2, 4 CPUs.",
    "## Full stack, compression over cleartext h2: connect-zig, connect-go and connect-rust",
    climb_header,
    "| connect-zig | uncompressed | 5 | 5–5 | 100% |  | +2.0% | 5.00 | p99 past 100 ms |",
]
log = "\n".join(log_lines)


def read(text, over="over TLS"):
    with tempfile.NamedTemporaryFile("w", suffix=".log") as file:
        file.write(text + "\n")
        file.flush()
        return compression_chart.read(file.name, over)


class ReadTest(unittest.TestCase):
    def test_reads_each_climb_with_its_shares_and_range(self):
        held, _, machine = read(log)
        self.assertEqual(
            sorted(held),
            [
                ("connect-rust", "uncompressed"),
                ("connect-zig", "gzip"),
                ("connect-zig", "uncompressed"),
                ("connect-zig", "zstd"),
            ],
        )
        self.assertEqual(
            held[("connect-zig", "gzip")],
            {
                "spans": 750_000,
                "gap": 0.02,
                "refused": False,
                "share": 75,
                "share_low": 70,
                "share_high": 80,
                "low": 700_000,
                "high": 800_000,
            },
        )
        self.assertIsNone(held[("connect-zig", "zstd")]["gap"])
        self.assertTrue(held[("connect-rust", "uncompressed")]["refused"])
        self.assertEqual(machine, "aarch64, Neoverse-N2")

    def test_reads_the_peak_of_512_spans_alone(self):
        _, peak, _ = read(log)
        self.assertEqual(
            peak,
            {
                ("connect-zig", "uncompressed"): {"rate": 1000, "low": 900, "high": 1100},
                ("connect-zig", "gzip"): {"rate": 800, "low": 750, "high": 850},
            },
        )

    def test_reads_the_report_of_its_transport(self):
        held, peak, _ = read(log, "over cleartext h2")
        self.assertEqual(list(held), [("connect-zig", "uncompressed")])
        self.assertEqual(peak, {})


class ShareTest(unittest.TestCase):
    def setUp(self):
        self.held, self.peak, _ = read(log)

    def test_uncompressed_spans_its_rounds_over_its_median(self):
        self.assertEqual(compression_chart.climb_share(self.held, "connect-zig", "uncompressed"), (100, 90, 120))

    def test_a_coding_spans_its_rounds_shares(self):
        self.assertEqual(compression_chart.climb_share(self.held, "connect-zig", "gzip"), (75, 70, 80))

    def test_a_report_of_one_climb_reaches_the_step_that_failed(self):
        held = {
            ("connect-zig", "uncompressed"): {"spans": 1000, "gap": 0.1, "refused": False},
            ("connect-zig", "gzip"): {"spans": 500, "gap": 0.2, "refused": False},
            ("connect-zig", "br"): {"spans": 400, "gap": None, "refused": False},
        }
        self.assertEqual(compression_chart.climb_share(held, "connect-zig", "gzip"), (50, 50, 60))
        # A floor has no whisker: both ends are its share.
        self.assertEqual(compression_chart.climb_share(held, "connect-zig", "br"), (40, 40, 40))

    def test_a_receiver_with_no_uncompressed_climb_has_no_share(self):
        held = {("connect-go", "gzip"): {"spans": 1, "gap": None, "refused": False}}
        self.assertIsNone(compression_chart.climb_share(held, "connect-go", "gzip"))

    def test_the_peak_share_divides_each_end_by_the_median_uncompressed(self):
        self.assertEqual(compression_chart.peak_share(self.peak, "connect-zig", "gzip"), (80, 75, 85))
        self.assertIsNone(compression_chart.peak_share(self.peak, "connect-go", "gzip"))

    def test_a_cap_marks_each_end_of_a_whisker_but_the_bar_end(self):
        self.assertEqual(compression_chart.caps(75, 70, 80), [70, 80])
        self.assertEqual(compression_chart.caps(50, 50, 60), [60])
        self.assertEqual(compression_chart.caps(100, 90, 100), [90])

    def test_the_title_names_each_coding_share(self):
        self.assertEqual(
            compression_chart.title_of(self.held, "over TLS"),
            "In gzip and zstd, connect-zig holds 75% and 90% of its uncompressed rate",
        )
        held = {("connect-zig", "uncompressed"): self.held[("connect-zig", "uncompressed")]}
        self.assertEqual(
            compression_chart.title_of(held, "over TLS"), "connect-zig's spans a second over TLS, uncompressed"
        )

    def test_a_label_marks_a_floor_and_slots_full(self):
        item = {"spans": 1500, "gap": None, "refused": True}
        self.assertEqual(compression_chart.climb_label(item, (75, 70, 80), "gzip"), "75% · ≥1,500/s · slots full")
        item = {"spans": 1500, "gap": 0.1, "refused": False}
        self.assertEqual(compression_chart.climb_label(item, (100, 90, 110), "uncompressed"), "1,500/s")


class DrawTest(unittest.TestCase):
    def setUp(self):
        self.held, self.peak, self.machine = read(log)

    def draw(self):
        return compression_chart.draw("tls", self.held, self.peak, self.machine, "run 1", "abc1234")

    def test_no_text_passes_an_edge_or_crosses_another(self):
        self.assertEqual(chart_text.faults(self.draw()), [])

    def test_the_widest_labels_stay_in_their_panel(self):
        # Each label at its longest: a rate of seven digits that is a floor, a share over 100%, and
        # a climb that ended on a call refused, beside a peak bar in each row.
        held, peak, machine = read(wide_log())
        svg = compression_chart.draw("tls", held, peak, machine, "run 1", "abc1234")
        self.assertIn("135% · ≥1,234,567/s · slots full", svg)
        self.assertEqual(chart_text.faults(svg), [])

    def test_the_subtitle_explains_each_mark_a_label_carries(self):
        # zstd's climb passed every step, and connect-rust's ended on a call refused.
        svg = self.draw()
        self.assertEqual(chart_text.unexplained_marks(svg, marks), [])
        self.assertEqual(lines_of_marks(svg), ["≥", "slots full"])
        for item in self.held.values():
            item["gap"] = item["gap"] if item["gap"] is not None else 0.01
            item["refused"] = False
        svg = self.draw()
        self.assertEqual(chart_text.unexplained_marks(svg, marks), [])
        self.assertEqual(lines_of_marks(svg), [])


def wide_log():
    """A report in which each label of the chart is as long as it gets."""
    servers, codings = ("connect-zig", "connect-go", "connect-rust"), ("uncompressed", "gzip", "zstd", "brotli")
    climbs = [
        f"| {server} | {coding} | 1,234,567 | 1,200,000–1,300,000 | {'100' if coding == 'uncompressed' else '135'}% "
        f"| {'' if coding == 'uncompressed' else '130–140%'} |  | 5.00 | a call refused |"
        for server in servers
        for coding in codings
    ]
    peaks = [
        f"| 512 spans | {server} | {coding} | 1,234 | 1,200–1,300 | 1.00 | 1.0 |"
        for server in servers
        for coding in codings
    ]
    return "\n".join(
        [
            log_lines[0],
            climb_header,
            log_lines[2],
            *climbs,
            peak_header,
            log_lines[9],
            *peaks,
            "Machine: x86_64, AMD EPYC 9V74 80-Core Processor.",
        ]
    )


def lines_of_marks(svg):
    """The marks the subtitle explains, in its order."""
    lines = [words for words, _, kind in chart_text.texts_of(svg) if kind == "sub"]
    return [mark for line in lines for mark in marks if line.startswith((f"{mark} marks", f'"{mark}" marks'))]


if __name__ == "__main__":
    unittest.main()
