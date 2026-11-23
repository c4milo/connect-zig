"""Tests of tools/speed_chart.py: its reading of the benchmark's table, and the claims of its title
(tools/scripts_test.sh)."""

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import speed_chart

header = "| message | operation | Zig ns/op | Go ns/op | Rust ns/op | Go time / Zig time | Rust time / Zig time |"


def table_text(rows):
    """The benchmark's table, after a line that names the machine."""
    return "\n".join(["Machine: x86_64, AMD EPYC 7763, 4 CPUs", header, "|---|---|--:|--:|--:|--:|--:|", *rows])


def speed_rows():
    """A row of each message and operation: connect-zig at 10 ns, Go at 40, and Buffa at 20,
    but Buffa beats connect-zig at the deep JSON decode, and is absent at the large one."""
    rows = []
    for message in speed_chart.msg_keys:
        for operation in speed_chart.op_keys:
            rust, rust_over_zig = "20", "2.0"
            if (message, operation) == ("deep", "JSON decode+walk"):
                rust, rust_over_zig = "5", "0.5"
            if message == "large" and operation == "JSON decode+walk":
                rust, rust_over_zig = "absent", "absent"
            rows.append(f"| {message} | {operation} | 10 | 40 | {rust} | 4.0 | {rust_over_zig} |")
    return rows


def read(reader, text):
    """What a chart's `read` gives for the text of a table."""
    with tempfile.NamedTemporaryFile("w", suffix=".md") as file:
        file.write(text + "\n")
        file.flush()
        return reader(file.name)


class SpeedChartTest(unittest.TestCase):
    def test_reads_each_speed_in_multiples_of_go(self):
        zig_speed, buffa_speed, buffa_over_zig, machine = read(speed_chart.read, table_text(speed_rows()))
        self.assertEqual(zig_speed[("small", "binary encode")], 4.0)
        self.assertEqual(buffa_speed[("small", "binary encode")], 2.0)
        self.assertEqual(buffa_speed[("deep", "JSON decode+walk")], 8.0)
        self.assertIsNone(buffa_speed[("large", "JSON decode+walk")])
        self.assertIsNone(buffa_over_zig[("large", "JSON decode+walk")])
        self.assertEqual(machine, "x86_64, AMD EPYC 7763")

    def test_the_title_states_what_the_numbers_show(self):
        zig_speed, _, buffa_over_zig, _ = read(speed_chart.read, table_text(speed_rows()))
        self.assertEqual(
            speed_chart.title_of(zig_speed, buffa_over_zig),
            "connect-zig is 4.0 to 4.0 times faster than Go; Buffa beats it in 1 of 15 cells",
        )
        faster = {key: 2.0 for key in buffa_over_zig}
        self.assertEqual(
            speed_chart.title_of(zig_speed, faster),
            "connect-zig is 4.0 to 4.0 times faster than Go and 2.0 to 2.0 times faster than Buffa",
        )
        # A cell at 1 is a tie: neither runtime beats the other there.
        tied = {key: 1.0 for key in buffa_over_zig}
        self.assertEqual(speed_chart.claim(list(tied.values()), "Buffa"), "Buffa beats connect-zig in no cell")
        self.assertEqual(speed_chart.claim([], "Buffa"), "Buffa did not run")


if __name__ == "__main__":
    unittest.main()
