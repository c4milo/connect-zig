"""Tests of tools/call_chart.py: its reading of the benchmark's table, and the claims of its title
(tools/scripts_test.sh)."""

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import call_chart

header = "| message | operation | Zig ns/op | Go ns/op | Rust ns/op | Go time / Zig time | Rust time / Zig time |"


def table_text(rows):
    """The benchmark's table, after a line that names the machine."""
    return "\n".join(["Machine: x86_64, AMD EPYC 7763, 4 CPUs", header, "|---|---|--:|--:|--:|--:|--:|", *rows])


def read(reader, text):
    """What a chart's `read` gives for the text of a table."""
    with tempfile.NamedTemporaryFile("w", suffix=".md") as file:
        file.write(text + "\n")
        file.flush()
        return reader(file.name)


class CallChartTest(unittest.TestCase):
    def test_reads_each_call_and_titles_both_ratios(self):
        rows = [
            "| small | Connect unary call | 500 | 2000 | 1000 | 4.0 | 2.0 |",
            "| small | gRPC unary call | 500 | 1500 | 1000 | 3.0 | 2.0 |",
            "| medium | Connect unary call | 1000 | 6000 | absent | 6.0 | absent |",
            "| medium | gRPC unary call | 1000 | 5000 | 2500 | 5.0 | 2.5 |",
            "| small | Connect unary call, 16 routes | 500 | 2000 | 1000 | 4.0 | 2.0 |",
        ]
        zig_speed, rust_speed, zig_us, _ = read(call_chart.read, table_text(rows))
        self.assertEqual(sorted(zig_speed.values()), [3.0, 4.0, 5.0, 6.0])
        self.assertEqual(rust_speed[("small", "Connect unary call")], 2.0)
        self.assertIsNone(rust_speed[("medium", "Connect unary call")])
        self.assertEqual(zig_us[("medium", "gRPC unary call")], 1.0)
        self.assertEqual(
            call_chart.title_of(zig_speed, rust_speed),
            "connect-zig is 3.0 to 6.0 times as fast as connect-go, 2.0 to 2.5 times connect-rust",
        )


if __name__ == "__main__":
    unittest.main()
