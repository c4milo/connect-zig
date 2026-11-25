"""Tests of tools/chart_change.py (tools/scripts_test.sh): the changes it marks, and each chart
drawn with the previous tag's values, whose marks must explain themselves and leave no text past
an edge, over another, or over a bar."""

import contextlib
import io
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import call_chart
import call_chart_test
import chart_change
import chart_text
import compression_chart
import compression_chart_test
import fullstack_chart
import fullstack_chart_test
import speed_chart
import speed_chart_test
import validate_chart
import validate_chart_test

machine = "aarch64, Neoverse-N2"


def previous_of(change, factors=(1.25, 0.89, 1.0), tag="v0.4.0", on=machine):
    """A previous tag's file of values: each value the chart recorded, divided in turn by each
    factor, so a value now is 25% better, 11% worse, and the same."""
    values = {}
    for index, (key, record) in enumerate(change.records.items()):
        values[key] = dict(record, value=record["value"] / factors[index % len(factors)])
    return {"version": chart_change.format_version, "tag": tag, "machine": on, "run": "1", "values": values}


class ChangeTest(unittest.TestCase):
    def change(self, was, now, higher_is_better=True):
        previous = {"version": 1, "tag": "v0.4.0", "machine": machine, "values": {"a": {"value": was}}}
        change = chart_change.Change(previous, machine)
        change.record("a", "a", now, higher_is_better)
        return change

    def test_marks_a_change_at_the_threshold_and_none_below_it(self):
        self.assertIn("▲5%", self.change(100, 105).mark("a"))
        self.assertIn("▲5%", self.change(0.2, 0.21).mark("a"))
        self.assertIn('class="better"', self.change(100, 105).mark("a"))
        self.assertEqual(self.change(100, 104.9).mark("a"), "")
        self.assertIn("▼5%", self.change(100, 95).mark("a"))
        self.assertEqual(self.change(100, 95.1).mark("a"), "")

    def test_a_label_starts_past_the_line_of_a_greater_previous_value(self):
        change = self.change(100, 50)
        self.assertEqual(change.end("a", lambda value: value, 50), 102)
        self.assertEqual(self.change(10, 50).end("a", lambda value: value, 50), 50)

    def test_a_lower_value_is_better_when_lower_is_better(self):
        self.assertIn("▲20%", self.change(100, 80, higher_is_better=False).mark("a"))

    def test_another_machine_marks_nothing_and_says_so(self):
        previous = {"version": 1, "tag": "v0.4.0", "machine": "x86_64, Xeon", "values": {"a": {"value": 1}}}
        change = chart_change.Change(previous, machine)
        change.record("a", "a", 2)
        self.assertEqual(change.mark("a"), "")
        self.assertEqual(change.line("a", lambda value: value, 0, 10), "")
        self.assertIn("another CPU model", change.note())

    def test_no_previous_tag_marks_nothing_and_adds_no_line(self):
        change = chart_change.Change(None, machine)
        change.record("a", "a", 2)
        self.assertEqual((change.mark("a"), change.note(), chart_change.note_height(change)), ("", None, 0))

    def test_a_file_of_another_version_is_no_previous_tag(self):
        with tempfile.TemporaryDirectory() as work:
            path = pathlib.Path(work, "chart.json")
            path.write_text(json.dumps({"version": chart_change.format_version + 1, "values": {}}))
            rest, previous = chart_change.split_arguments(["chart.py", "a", chart_change.option, str(path)])
        self.assertEqual((rest, previous), (["chart.py", "a"], None))

    def test_writes_the_values_beside_the_chart(self):
        change = self.change(100, 105)
        with tempfile.TemporaryDirectory() as work:
            change.write(pathlib.Path(work, "speed.svg"), "speed", "7", "abc")
            written = chart_change.load(pathlib.Path(work, "speed.json"))
        self.assertEqual((written["chart"], written["machine"]), ("speed", machine))
        self.assertEqual(written["values"]["a"]["value"], 105)


class ChartsTest(unittest.TestCase):
    """Each chart, drawn with a previous tag's values, marks a change each way and stays legible."""

    def check(self, draw):
        first = chart_change.Change(None, machine)
        draw(first)
        self.assertTrue(first.records)
        change = chart_change.Change(previous_of(first), machine)
        svg = draw(change)
        self.assertIn("▲25%", svg)
        self.assertIn("▼11%", svg)
        self.assertIn('class="was"', svg)
        self.assertIn("▲ marks a value 5% or more better than v0.4.0's", svg)
        self.assertEqual(chart_text.faults(svg), [])

    def test_speed(self):
        tables = speed_chart_test.table_text(speed_chart_test.speed_rows())
        with tempfile.NamedTemporaryFile("w", suffix=".md") as file:
            file.write(tables)
            file.flush()
            zig, buffa, buffa_over_zig, _ = speed_chart.read(file.name)
        versions = speed_chart_test.versions
        self.check(lambda change: speed_chart.draw(zig, buffa, buffa_over_zig, machine, "2", "b", versions, change))

    def test_call(self):
        zig, rust, zig_us, _ = call_chart_test.read(call_chart.read, call_chart_test.table_text(call_chart_test.rows))
        versions = call_chart_test.versions
        self.check(lambda change: call_chart.draw(zig, rust, zig_us, machine, "2", "b", versions, change))

    def test_validate(self):
        times, _ = validate_chart_test.read(validate_chart_test.table)
        versions = ("v1.4.1", "1.1.0", "0.8.0", "0.6.1")

        def draw(change):
            with contextlib.redirect_stdout(io.StringIO()):
                return validate_chart.draw(times, machine, "2", "b", versions, change)

        self.check(draw)

    def test_fullstack(self):
        held, steps, _ = fullstack_chart_test.read(fullstack_chart_test.validate_log, validate=True)
        self.check(lambda change: fullstack_chart.draw("validate", held, steps, machine, "2", "b", change))

    def test_compression(self):
        held, peak, _ = compression_chart_test.read(compression_chart_test.wide_log())
        self.check(lambda change: compression_chart.draw("tls", held, peak, machine, "2", "b", change))


if __name__ == "__main__":
    unittest.main()
