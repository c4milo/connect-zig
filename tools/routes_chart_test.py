"""Tests of tools/routes_chart.py: its reading of the benchmark's table, its axis, and its labels
(tools/scripts_test.sh)."""

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import routes_chart

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


class RoutesChartTest(unittest.TestCase):
    def test_reads_the_small_message_by_route_count(self):
        rows = [
            "| small | Connect unary call | 100 | 400 | 200 | 4.0 | 2.0 |",
            "| small | Connect unary call, 256 routes | 110 | 600 | absent | 5.5 | absent |",
            "| medium | Connect unary call, 256 routes | 1 | 1 | 1 | 1.0 | 1.0 |",
            "| small | gRPC unary call, 16 routes | 100 | 400 | 200 | 4.0 | 2.0 |",
        ]
        times, machine = read(routes_chart.read, table_text(rows))
        self.assertEqual(
            sorted(times), [("Connect unary call", 1), ("Connect unary call", 256), ("gRPC unary call", 16)]
        )
        self.assertEqual(
            times[("Connect unary call", 256)], {"connect-zig": 110.0, "connect-rust": None, "connect-go": 600.0}
        )
        self.assertEqual(routes_chart.counts_of(times), [1, 16, 256])
        self.assertAlmostEqual(routes_chart.ratio(times, "Connect unary call", 256, "connect-go"), 1.5)
        self.assertIsNone(routes_chart.ratio(times, "Connect unary call", 256, "connect-rust"))
        self.assertEqual(machine, "x86_64, AMD EPYC 7763")

    def test_a_change_reads_in_whole_percent_with_its_sign(self):
        self.assertEqual(routes_chart.percent(1.104), "+10%")
        self.assertEqual(routes_chart.percent(0.996), "+0%")
        self.assertEqual(routes_chart.percent(0.9), "-10%")

    def test_the_axis_holds_every_ratio_on_its_step(self):
        # 0.9 to 1.1 at least, on steps of 5%, and of 10% past a span of 0.5.
        low, high, step = routes_chart.scale([0.97, 1.02])
        self.assertEqual((round(low, 2), round(high, 2), step), (0.9, 1.15, 0.05))
        low, high, step = routes_chart.scale([0.95, 1.6])
        self.assertEqual((round(low, 2), round(high, 2), step), (0.9, 1.7, 0.1))

    def test_end_labels_stay_a_line_apart(self):
        self.assertEqual(
            routes_chart.spread([[50, 1, "b"], [45, 1, "a"], [100, 1, "c"]]),
            [[45, 1, "a"], [58, 1, "b"], [100, 1, "c"]],
        )


if __name__ == "__main__":
    unittest.main()
