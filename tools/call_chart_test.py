"""Tests of tools/call_chart.py: its reading of the benchmark's table, and the claims of its title
(tools/scripts_test.sh)."""

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import call_chart
import chart_text

header = "| message | operation | Zig ns/op | Go ns/op | Rust ns/op | Go time / Zig time | Rust time / Zig time |"


def table_text(rows):
    """The benchmark's table, after a line that names the machine."""
    return "\n".join(["Machine: x86_64, AMD EPYC 7763, 4 CPUs", header, "|---|---|--:|--:|--:|--:|--:|", *rows])


# The versions the legend names, so a test reads no lock file.
versions = ("v1.18.1", "0.9.1")
# The least gap the chart keeps between the middles of two tick labels (call_chart.layout_of).
tick_gap_min = 28
# The longest machine the subtitle has named.
long_machine = "x86_64, AMD EPYC 9V74 80-Core Processor"
rows = [
    "| small | Connect unary call | 500 | 2000 | 1000 | 4.0 | 2.0 |",
    "| small | gRPC unary call | 500 | 1500 | 1000 | 3.0 | 2.0 |",
    "| medium | Connect unary call | 1000 | 6000 | absent | 6.0 | absent |",
    "| medium | gRPC unary call | 1000 | 5000 | 2500 | 5.0 | 2.5 |",
    "| small | Connect unary call, 16 routes | 500 | 2000 | 1000 | 4.0 | 2.0 |",
]


def scaled(top):
    """Each call at `top` times connect-go's speed for connect-zig, at half that for connect-rust,
    and at 1.5 µs a call for connect-zig."""
    keys = [(message, operation) for message in call_chart.msg_keys for operation in call_chart.op_keys]
    return {key: float(top) for key in keys}, {key: top / 2 for key in keys}, {key: 1.5 for key in keys}


def read(reader, text):
    """What a chart's `read` gives for the text of a table."""
    with tempfile.NamedTemporaryFile("w", suffix=".md") as file:
        file.write(text + "\n")
        file.flush()
        return reader(file.name)


class CallChartTest(unittest.TestCase):
    def test_reads_each_call_and_titles_both_ratios(self):
        zig_speed, rust_speed, zig_us, _ = read(call_chart.read, table_text(rows))
        self.assertEqual(sorted(zig_speed.values()), [3.0, 4.0, 5.0, 6.0])
        self.assertEqual(rust_speed[("small", "Connect unary call")], 2.0)
        self.assertIsNone(rust_speed[("medium", "Connect unary call")])
        self.assertEqual(zig_us[("medium", "gRPC unary call")], 1.0)
        self.assertEqual(
            call_chart.title_of(zig_speed, rust_speed),
            "connect-zig is 3.0 to 6.0 times as fast as connect-go, 2.0 to 2.5 times connect-rust",
        )

    def test_reads_a_log_that_github_wrote(self):
        text = table_text(rows)
        self.assertEqual(read(call_chart.read, chart_text.github_log(text)), read(call_chart.read, text))

    def test_no_text_passes_an_edge_or_crosses_another(self):
        zig_speed, rust_speed, zig_us, machine = read(call_chart.read, table_text(rows))
        svg = call_chart.draw(zig_speed, rust_speed, zig_us, machine, "run 1", "abc1234", versions)
        self.assertEqual(chart_text.faults(svg), [])

    def test_tick_labels_stay_apart_at_every_scale(self):
        for top in range(2, 61):
            zig_speed, rust_speed, zig_us = scaled(top)
            svg = call_chart.draw(zig_speed, rust_speed, zig_us, long_machine, "run 1", "abc1234", versions)
            with self.subTest(top=top):
                self.assertGreaterEqual(chart_text.tick_gap(svg), tick_gap_min)
                self.assertEqual(chart_text.faults(svg), [])


if __name__ == "__main__":
    unittest.main()
