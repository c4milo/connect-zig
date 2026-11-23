"""Tests of tools/bench_median.py: the round it picks for each row (tools/scripts_test.sh)."""

import contextlib
import io
import os
import pathlib
import sys
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import bench_median


def round_text(rows):
    """A round's table: each row a message, an operation, and its ns/op."""
    lines = [
        "Machine: x86_64",
        "",
        "| message | operation | bytes | ns/op | MB/s |",
        "| --- | --- | ---: | ---: | ---: |",
    ]
    lines += [f"| {message} | {operation} | 40 | {ns} | {ns * 2} |" for message, operation, ns in rows]
    return "\n".join(lines) + "\n"


class BenchMedianTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.folder.cleanup()

    def rounds(self, *tables):
        paths = []
        for index, rows in enumerate(tables):
            path = os.path.join(self.folder.name, f"zig-{index + 1}.md")
            pathlib.Path(path).write_text(round_text(rows))
            paths.append(path)
        return paths

    def test_picks_the_round_of_the_median_ns(self):
        paths = self.rounds([("small", "encode", 30)], [("small", "encode", 10)], [("small", "encode", 20)])
        rows, order = bench_median.read(paths)
        self.assertEqual(order, [("small", "encode")])
        self.assertEqual(bench_median.median_row(rows[("small", "encode")]), ["small", "encode", "40", "20", "40"])

    def test_an_even_count_takes_the_lower_middle_round(self):
        rounds = [["small", "encode", "40", ns, "1"] for ns in ("40", "10", "30", "20")]
        self.assertEqual(bench_median.median_row(rounds)[3], "20")

    def test_a_row_a_round_lacks_takes_the_median_of_the_others(self):
        paths = self.rounds(
            [("small", "encode", 10), ("deep", "decode", 50)],
            [("small", "encode", 12)],
            [("small", "encode", 11), ("deep", "decode", 70)],
        )
        output = io.StringIO()
        with contextlib.redirect_stdout(output), unittest.mock.patch.object(sys, "argv", ["bench_median.py", *paths]):
            bench_median.main()
        self.assertEqual(output.getvalue(), "| small | encode | 40 | 11 | 22 |\n| deep | decode | 40 | 50 | 100 |\n")

    def test_skips_the_header_the_rule_and_other_tables(self):
        text = round_text([("small", "encode", 10)]) + "| case | Zig ns |\n| a | 1 |\n"
        path = os.path.join(self.folder.name, "zig-1.md")
        pathlib.Path(path).write_text(text)
        rows, order = bench_median.read([path])
        self.assertEqual(order, [("small", "encode")])
        self.assertEqual(len(rows[("small", "encode")]), 1)


if __name__ == "__main__":
    unittest.main()
