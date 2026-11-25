"""Tests of tools/charts_compare.py (tools/scripts_test.sh): the counts, the table of what moved
past the threshold, and the charts it cannot compare."""

import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import chart_change
import charts_compare

machine = "aarch64, Neoverse-N2"


def write(folder, name, values, on=machine, tag=None):
    """A chart's file of values, from a value of each label."""
    records = {label: {"label": label, "value": value, "higher_is_better": True} for label, value in values.items()}
    folder.mkdir(parents=True, exist_ok=True)
    text = {"version": chart_change.format_version, "machine": on, "tag": tag, "run": "1", "values": records}
    (folder / f"{name}.json").write_text(json.dumps(text))


class CompareTest(unittest.TestCase):
    def compare(self, previous, current):
        with tempfile.TemporaryDirectory() as work:
            before, after = pathlib.Path(work, "before"), pathlib.Path(work, "after")
            for name, (values, on) in previous.items():
                write(before, name, values, on, "v0.4.0")
            for name, values in current.items():
                write(after, name, values, tag="v0.5.0")
            return charts_compare.compare(before, after)

    def test_counts_and_lists_each_value_past_the_threshold(self):
        text = self.compare(
            {"speed": ({"a": 100, "b": 100, "c": 100}, machine)},
            {"speed": {"a": 120, "b": 90, "c": 103, "d": 7}},
        )
        self.assertIn("against v0.4.0: 1 better and 1 worse by 5% or more, of 4.", text)
        moved = text.split("<details>")[0]
        self.assertIn("| speed | a | 100.00 | 120.00 | ▲ 20% better |", moved)
        self.assertIn("| speed | b | 100.00 | 90.00 | ▼ 10% worse |", moved)
        self.assertNotIn("| speed | c |", moved)
        self.assertIn("| speed | c | 100.00 | 103.00 | ≈ +3.0% |", text)
        self.assertIn("| speed | d | – | 7.00 | new |", text)

    def test_a_chart_on_another_machine_compares_nothing(self):
        text = self.compare({"speed": ({"a": 100}, "x86_64, Xeon")}, {"speed": {"a": 200}})
        self.assertIn("another CPU model than v0.4.0's, so they compare nothing: speed.", text)
        self.assertNotIn("▲", text)

    def test_no_previous_file_says_so(self):
        text = self.compare({}, {"speed": {"a": 1}})
        self.assertIn("The previous tag has no file of values", text)
        self.assertTrue(text.startswith(charts_compare.heading))

    def test_a_rate_prints_with_thousands(self):
        self.assertEqual((charts_compare.number(711570.4), charts_compare.number(3.214)), ("711,570", "3.21"))


if __name__ == "__main__":
    unittest.main()
