"""Tests of tools/fullstack_chart.py: its reading of a production report, and the whiskers of its
bars (tools/scripts_test.sh)."""

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import chart_text
import fullstack_chart
import fullstack_chart_text

# The marks a label of the chart can carry.
marks = ("≥", "≤", "?")

held_header = (
    "| server | spans/s held | range | resolution | calls/s | p50 ms | p99 ms | core busy | load busy | CPU µs a span "
    "| peak MiB | p99 ≤ 10 ms | the next step |"
)
log_lines = [
    "2026-11-23T10:00:00.1234Z ## Full stack, production over TLS: one gateway core for 33,000 servers",
    "",
    held_header,
    "|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|",
    "| connect-zig | 1,000,000 | 900,000–1,100,000 | +2.5% | 1 | 1 | 40.5 | 90% | 10% | 1 | 1 | 1 | p99 past 100 ms |",
    "| Collector | 100,000 | 90,000–110,000 |  | 1 | 1 | 20 | 90% | 10% | 1 | 1 | 1 | none: the last step passed |",
    "| Vector | none | | | | | | | | | | | a call refused |",
    "",
    "| server | spans/s sent | spans/s taken | p99 ms | core busy | the step |",
    "| connect-zig | 5 | 5 | 1 | 1% | held |",
    "",
    "| exports a connection a second | spans/s sent | connect-zig p99 | connect-zig core | Collector p99 | Collector core |",
    "|--:|--:|--:|--:|--:|--:|",
    "| 1 | 35,600 | 2.00 | 10% | 5.00 | 50% |",
    "| 2 | 71,200 | 3.00 | 20% | 150.00 (p99) | 99% |",
    "| 4 | 142,400 | 200.00 (refused) | 40% |  |  |",
    "Machine: x86_64, AMD EPYC 7763, 4 CPUs, Linux 6.8.",
    "## Full stack, production over cleartext h2: one gateway core for 33,000 servers",
    held_header,
    "| connect-zig | 7 | 7–7 | +1.0% | 1 | 1 | 1 | 1% | 1% | 1 | 1 | 1 | p99 past 100 ms |",
]
log = "\n".join(log_lines)
# The TLS table of every Connect receiver beside its twin that validates each export.
validate_names = [
    ("connect-zig", "800,000"),
    ("connect-zig + protovalidate", "700,000"),
    ("connect-go", "100,000"),
    ("connect-go + protovalidate-go", "60,000"),
    ("connect-rust", "300,000"),
    ("connect-rust + protovalidate-buffa", "280,000"),
]


def validate_log_text():
    """The TLS table of every Connect receiver beside its twin that validates, with each step."""
    return "\n".join(
        [
            "## Full stack, production over TLS: one gateway core for 33,000 servers",
            held_header,
            "|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|",
            *(
                f"| {name} | {spans} | {spans}–{spans} | +2.5% | 1 | 1 | 40.5 | 90% | 10% | 1 | 1 | 1 | p99 past 100 ms |"
                for name, spans in validate_names
            ),
            "",
            "| exports a connection a second | spans/s sent | "
            + " | ".join(f"{name} p99 | {name} core" for name, _ in validate_names)
            + " |",
            "|--:|--:|" + "--:|--:|" * len(validate_names),
            "| 1 | 35,600 | " + " | ".join("2.00 | 10%" for _ in validate_names) + " |",
            "| 2 | 71,200 | " + " | ".join("150.00 (p99) | 99%" for _ in validate_names) + " |",
            "Machine: aarch64, Neoverse-N2, 4 CPUs, Linux 6.8.",
        ]
    )


validate_log = validate_log_text()


def read(text, over="over TLS", validate=False):
    with tempfile.NamedTemporaryFile("w", suffix=".log") as file:
        file.write(text + "\n")
        file.flush()
        return fullstack_chart.read(file.name, over, fullstack_chart.looks_of(validate))


class ReadTest(unittest.TestCase):
    def test_reads_the_table_of_the_transport_alone(self):
        held, _, machine = read(log)
        self.assertEqual(sorted(held), ["Collector", "connect-zig"])
        self.assertEqual(
            held["connect-zig"],
            {"spans": 1_000_000, "p99": 40.5, "gap": 0.025, "floor": False, "low": 900_000, "high": 1_100_000},
        )
        # A climb whose every step passed gives no resolution: its rate is a floor.
        self.assertEqual((held["Collector"]["gap"], held["Collector"]["floor"]), (None, True))
        self.assertEqual(machine, "x86_64, AMD EPYC 7763")

    def test_reads_each_step_of_the_first_round_with_its_failure(self):
        _, steps, _ = read(log)
        self.assertEqual(
            steps,
            [
                {"sent": 35600, "connect-zig": (2.0, None), "Collector": (5.0, None)},
                {"sent": 71200, "connect-zig": (3.0, None), "Collector": (150.0, "p99")},
                {"sent": 142400, "connect-zig": (200.0, "refused")},
            ],
        )

    def test_reads_the_cleartext_table_for_cleartext(self):
        held, _, _ = read(log, "over cleartext h2")
        self.assertEqual(list(held), ["connect-zig"])
        self.assertEqual(held["connect-zig"]["spans"], 7)


class WhiskerTest(unittest.TestCase):
    def test_a_report_of_rounds_spans_the_range_with_a_cap_at_each_end(self):
        item = {"spans": 1000, "low": 800, "high": 1200, "gap": 0.02}
        # The panel's greatest rate, 2000, is 200 pixels wide from 100.
        start, end, caps = fullstack_chart.whisker(item, 2000, 100, 200, 100)
        self.assertEqual((start, end, caps), (180, 220, (180, 220)))

    def test_a_report_of_one_climb_reaches_the_step_that_failed(self):
        start, end, caps = fullstack_chart.whisker({"spans": 1000, "gap": 0.5}, 2000, 100, 200, 100)
        # The bar ends at 200, and the step that failed lies 50% above its rate.
        self.assertEqual((start, end, caps), (200, 250, (250,)))

    def test_a_floor_has_no_whisker(self):
        self.assertIsNone(fullstack_chart.whisker({"spans": 1000, "gap": None}, 2000, 100, 200, 100))


class TitleTest(unittest.TestCase):
    def test_a_ratio_over_a_floor_is_at_most_its_value(self):
        held, _, _ = read(log)
        self.assertEqual(fullstack_chart_text.bound(held, "connect-zig", "Collector"), ("≤", "at most "))
        self.assertEqual(fullstack_chart_text.bound(held, "Collector", "connect-zig"), ("≥", "at least "))
        self.assertEqual(fullstack_chart_text.bound(held, "connect-zig", "connect-zig"), ("", ""))
        title = fullstack_chart.title_of(held, ["connect-zig", "Collector"], False)
        self.assertEqual(
            title, "One core holds at most 10.0 times the Collector's spans a second, with p99 under 100 ms"
        )

    def test_the_bar_label_gives_connect_zig_over_the_server(self):
        held, _, _ = read(log)
        self.assertEqual(fullstack_chart.bar_ratio(held, "Collector", False), ", connect-zig ≤10.0×")
        self.assertEqual(fullstack_chart.bar_ratio(held, "connect-zig", False), "")


class LabelTest(unittest.TestCase):
    def test_a_label_at_the_right_edge_moves_left_and_up(self):
        lay = type("Layout", (), {"line_right": 800, "top": 100})
        placed = fullstack_chart.place_labels(lay, [[300, 790, "refused"], [200, 400, "load full"]])
        self.assertEqual(
            [(y, round(left, 1), text) for y, left, _, text in placed],
            [(200, 408, "load full"), (288, 738.6, "refused")],
        )

    def test_a_label_that_would_cover_another_moves_down_a_line(self):
        lay = type("Layout", (), {"line_right": 800, "top": 100})
        placed = fullstack_chart.place_labels(lay, [[200, 400, "p99 120 ms"], [205, 420, "refused"]])
        self.assertEqual([y for y, _, _, _ in placed], [200, 213])

    def test_the_same_label_a_few_pixels_away_is_drawn_once(self):
        unique = fullstack_chart.unique_labels([[200, 400, "refused"], [203, 402, "refused"], [203, 402, "load full"]])
        self.assertEqual(unique, [[200, 400, "refused"], [203, 402, "load full"]])


class DrawTest(unittest.TestCase):
    def draw(self, held, steps, machine, transport="tls"):
        return fullstack_chart.draw(transport, held, steps, machine, "run 1", "abc1234")

    def test_no_text_passes_an_edge_or_crosses_another(self):
        held, steps, machine = read(log)
        self.assertEqual(chart_text.faults(self.draw(held, steps, machine)), [])
        held, steps, machine = read(validate_log, validate=True)
        self.assertEqual(chart_text.faults(self.draw(held, steps, machine, "validate")), [])

    def test_the_subtitle_explains_each_mark_a_label_carries(self):
        # The Collector's climb passed every step: its rate is at least its value, and connect-zig's
        # ratio over it at most its value.
        held, steps, machine = read(log)
        svg = self.draw(held, steps, machine)
        self.assertEqual(chart_text.unexplained_marks(svg, marks), [])
        self.assertEqual(lines_of_marks(svg), ["≥", "≤"])
        # Both climbs passed every step: the ratio of two floors is bounded by neither.
        held["connect-zig"].update(gap=None, floor=True)
        svg = self.draw(held, steps, machine)
        self.assertEqual(chart_text.unexplained_marks(svg, marks), [])
        self.assertEqual(lines_of_marks(svg), ["≥", "?"])
        # No climb passed every step: no label carries a mark, and the subtitle explains none.
        for item in held.values():
            item.update(gap=0.05, floor=False)
        svg = self.draw(held, steps, machine)
        self.assertEqual(chart_text.unexplained_marks(svg, marks), [])
        self.assertEqual(lines_of_marks(svg), [])


def lines_of_marks(svg):
    """The marks the subtitle explains, in its order."""
    lines = [words for words, _, kind in chart_text.texts_of(svg) if kind == "sub"]
    return [mark for line in lines for mark in marks if line.startswith(f"{mark} marks")]


if __name__ == "__main__":
    unittest.main()
