"""Tests of tools/validate_chart.py: its reading of the validation benchmark's first table, and each
implementation's speed (tools/scripts_test.sh)."""

import contextlib
import io
import pathlib
import sys
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import validate_chart

header = "| case | Zig total ns | Go total ns | Node total ns | buffa total ns | prost total ns |"


def row(case, zig, go, node, buffa, prost):
    return f"| {case} | {zig} | {go} | {node} | {buffa} | {prost} |"


def table_text():
    """The benchmark's output: a table of each case, then a second table the chart does not read."""
    rows = [row(case, 10, 100, 400, 50, 25) for case in validate_chart.cases]
    lines = ["Machine: aarch64, Neoverse-N2", "## Decode and validate", header, "|---|--:|--:|--:|--:|--:|", *rows]
    return "\n".join([*lines, "## Validate alone", header, row("small valid", 1, 1, 1, 1, 1)])


table = table_text()


def read(text):
    with tempfile.NamedTemporaryFile("w", suffix=".md") as file:
        file.write(text + "\n")
        file.flush()
        return validate_chart.read(file.name)


class ValidateChartTest(unittest.TestCase):
    def test_reads_the_first_table_alone(self):
        times, machine = read(table)
        self.assertEqual(sorted(times), sorted(validate_chart.cases))
        self.assertEqual(times["small valid"], {"Zig": 10, "Go": 100, "Node": 400, "buffa": 50, "prost": 25})
        self.assertEqual(machine, "aarch64, Neoverse-N2")

    def test_a_speed_is_go_time_over_the_implementation_time(self):
        times, _ = read(table)
        speed = validate_chart.speed_of(times)
        self.assertEqual(speed["rules invalid"], {"Zig": 10.0, "buffa": 2.0, "prost": 4.0, "Node": 0.25})

    def test_a_missing_case_stops_the_chart(self):
        text = "\n".join(line for line in table.split("\n") if "rules valid" not in line)
        with tempfile.NamedTemporaryFile("w", suffix=".md") as file:
            file.write(text + "\n")
            file.flush()
            arguments = ["validate_chart.py", file.name, "1", "abc", "/dev/null"]
            with unittest.mock.patch.object(sys, "argv", arguments), self.assertRaises(SystemExit) as stop:
                validate_chart.main()
        self.assertEqual(stop.exception.code, f"{file.name}: no row for rules valid")

    def test_the_chart_names_the_fastest_and_each_speed(self):
        times, machine = read(table)
        with contextlib.redirect_stdout(io.StringIO()):
            svg = validate_chart.draw(times, machine, "7", "abc", ("v1", "v2", "v3", "v4"))
        self.assertIn("connect-zig decodes and validates 10 to 10 times as fast as protovalidate-go", svg)
        self.assertIn("connect-zig is the fastest in 6 of 6 cases.", svg)
        self.assertIn(">10×, 10 ns</text>", svg)
        self.assertIn(">0.25×</text>", svg)


if __name__ == "__main__":
    unittest.main()
