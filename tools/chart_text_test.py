"""Tests of tools/chart_text.py: the box of each text, and what it finds wrong in a chart
(tools/scripts_test.sh)."""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import chart_text

style = (
    "<style>text { font-family: Helvetica; } .title { font-size: 20px; font-weight: 600; } "
    ".tick { font-size: 10px; } .sub { font-size: 10px; } .val { font-size: 10px; }</style>"
)


def svg_of(*texts, width=200, height=100):
    """A chart of the given texts, each a `<text>` element."""
    return f'<svg viewBox="0 0 {width} {height}">{style}{"".join(texts)}</svg>'


def text(words, x, y, kind="tick", anchor=None):
    """A `<text>` element of a class, at an anchor."""
    anchored = f' text-anchor="{anchor}"' if anchor else ""
    return f'<text class="{kind}" x="{x}" y="{y}"{anchored}>{words}</text>'


class WidthTest(unittest.TestCase):
    def test_a_text_takes_helveticas_width_at_its_size(self):
        # "Hi" is 722 + 222 thousandths of an em; at 10 px, 9.44 px.
        self.assertAlmostEqual(chart_text.width_of("Hi", 10, False), 9.44)
        self.assertAlmostEqual(chart_text.width_of("Hi", 10, True), 9.44 * chart_text.bold_factor)
        # A glyph outside the tables takes a whole em.
        self.assertAlmostEqual(chart_text.width_of("☃", 10, False), 10)

    def test_the_anchor_places_the_box(self):
        font = (10, False)
        self.assertEqual(chart_text.box_of("0", 50, 20, "start", font)[:2], (50, 55.56))
        self.assertEqual(chart_text.box_of("0", 50, 20, "middle", font)[:2], (47.22, 52.78))
        self.assertEqual(chart_text.box_of("0", 50, 20, "end", font)[:2], (44.44, 50))
        self.assertEqual(chart_text.box_of("0", 50, 20, "start", font)[2:], (12, 22))

    def test_each_class_takes_its_font_from_the_style(self):
        self.assertEqual(chart_text.fonts_of(svg_of())["title"], (20, True))
        self.assertEqual(chart_text.fonts_of(svg_of())["tick"], (10, False))
        words, _, kind = chart_text.texts_of(svg_of(text("a &amp; <tspan>b</tspan>", 5, 20)))[0]
        self.assertEqual((words, kind), ("a & b", "tick"))


class FaultTest(unittest.TestCase):
    def test_a_text_past_an_edge_is_found(self):
        self.assertEqual(chart_text.faults(svg_of(text("inside", 10, 20))), [])
        self.assertEqual(chart_text.outside(svg_of(text("right", 195, 20))), ["right"])
        self.assertEqual(chart_text.outside(svg_of(text("left", 5, 20, anchor="end"))), ["left"])
        self.assertEqual(chart_text.outside(svg_of(text("top", 10, 5))), ["top"])
        self.assertEqual(chart_text.outside(svg_of(text("bottom", 10, 99))), ["bottom"])

    def test_two_texts_drawn_over_each_other_are_found(self):
        self.assertEqual(chart_text.overlapping(svg_of(text("one", 10, 20), text("two", 20, 20))), [("one", "two")])
        # A line below, or a word beside, crosses nothing.
        self.assertEqual(chart_text.overlapping(svg_of(text("one", 10, 20), text("two", 10, 30))), [])
        self.assertEqual(chart_text.overlapping(svg_of(text("one", 10, 20), text("two", 40, 20))), [])

    def test_the_least_gap_between_two_ticks_on_a_line(self):
        ticks = svg_of(
            text("1", 10, 90, anchor="middle"), text("2", 40, 90, anchor="middle"), text("3", 55, 90, anchor="middle")
        )
        self.assertAlmostEqual(chart_text.tick_gap(ticks), 15)
        # Ticks on two lines are not measured against each other.
        self.assertIsNone(chart_text.tick_gap(svg_of(text("1", 10, 80), text("2", 12, 90))))


class BarTest(unittest.TestCase):
    def test_a_bar_takes_the_box_of_its_rect_or_its_path(self):
        rect = '<rect x="10" y="20" width="30" height="8" fill="var(--zig)"/>'
        path = '<path d="M10,40 h26 a4,4 0 0 1 4,4 v2 a4,4 0 0 1 -4,4 h-26 z" fill="var(--zig)"/>'
        surface = '<rect width="200" height="100" fill="var(--surface)"/>'
        self.assertEqual(chart_text.bars_of(svg_of(rect, path, surface)), [(10, 40, 20, 28), (10, 40, 40, 50)])
        # A path of another shape, such as a line through points, is no bar.
        self.assertIsNone(chart_text.path_box("M10,10 L40,40"))

    def test_a_text_over_a_bar_is_found(self):
        bar = '<rect x="10" y="20" width="60" height="10" fill="var(--zig)"/>'
        self.assertEqual(chart_text.faults(svg_of(bar, text("past it", 74, 29, "val"))), [])
        self.assertEqual(chart_text.over_bars(svg_of(bar, text("on it", 40, 29, "val"))), ["on it"])
        self.assertEqual(chart_text.faults(svg_of(bar, text("on it", 40, 29, "val"))), ["drawn over a bar: on it"])


class MarkTest(unittest.TestCase):
    def test_a_mark_is_explained_when_a_label_carries_it(self):
        label, note = text("≥1,000/s", 10, 20, "val"), text("≥ marks a floor.", 10, 40, "sub")
        self.assertEqual(chart_text.unexplained_marks(svg_of(label, note), ["≥"]), [])
        self.assertEqual(chart_text.unexplained_marks(svg_of(label), ["≥"]), ["≥: carried alone"])
        self.assertEqual(chart_text.unexplained_marks(svg_of(note), ["≥"]), ["≥: explained alone"])
        quoted = text("&quot;slots full&quot; marks a refusal.", 10, 40, "sub")
        full = text("1,000/s · slots full", 10, 20, "val")
        self.assertEqual(chart_text.unexplained_marks(svg_of(full, quoted), ["slots full"]), [])

    def test_a_log_that_github_wrote_has_the_time_before_each_line(self):
        self.assertEqual(chart_text.github_log("a\nb"), f"{chart_text.github_stamp}a\n{chart_text.github_stamp}b")


if __name__ == "__main__":
    unittest.main()
