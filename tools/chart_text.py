"""The room each text of a chart's SVG takes, for the charts' tests (tools/scripts_test.sh).

A test draws a chart, then asks what a reader would see wrong: a text past the chart's edge, or
two texts drawn over each other. A text's width comes from Helvetica's widths of each glyph, which
Arial, a font of each chart's list, shares. A glyph outside the table counts as one em, so a test
errs toward a finding. A text takes the height of its font, from its baseline up to 0.8 of its
size and down to 0.2.
"""

import html
import itertools
import re

# Helvetica's width of each glyph from the space to the tilde, in thousandths of an em, as Adobe's
# font metrics give them.
# fmt: off
ascii_widths = [
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
]
# fmt: on
# The glyphs past ASCII that the charts write.
other_widths = {"×": 584, "≥": 584, "≤": 584, "µ": 556, "–": 556, "—": 1000, "·": 278, "…": 1000, "−": 584}
# A glyph neither table holds.
unknown_width = 1000
# A bold text, of weight 600 or more, is wider than its regular face by up to this share.
bold_factor = 1.08
# The share of a text's size above its baseline, and below it.
ascent, descent = 0.8, 0.2
# How a style rule of the SVG names a class's font: `.tick { font-size: 11px; font-weight: 600; }`.
rule_pattern = re.compile(r"\.([\w-]+)\s*\{([^}]*)\}")
text_pattern = re.compile(r"<text\b([^>]*)>(.*?)</text>", re.DOTALL)
attribute_pattern = re.compile(r'([\w-]+)="([^"]*)"')
rect_pattern = re.compile(r"<rect\b([^>]*)>")
path_pattern = re.compile(r'<path\b[^>]*\bd="([^"]*)"')
command_pattern = re.compile(r"([A-Za-z])([^A-Za-z]*)")
number_pattern = re.compile(r"-?[0-9.]+")


def glyph_width(glyph):
    """A glyph's width in thousandths of an em."""
    code = ord(glyph)
    if ord(" ") <= code <= ord("~"):
        return ascii_widths[code - ord(" ")]
    return other_widths.get(glyph, unknown_width)


def width_of(text, size, bold):
    """The width of a text at a font size, in the SVG's units."""
    width = sum(glyph_width(glyph) for glyph in text) * size / 1000
    return width * bold_factor if bold else width


def fonts_of(svg):
    """Each class's font size and whether it is bold, from the SVG's style sheet."""
    fonts = {}
    for name, body in rule_pattern.findall(svg):
        size = re.search(r"font-size:\s*([0-9.]+)px", body)
        if size:
            weight = re.search(r"font-weight:\s*([0-9]+)", body)
            fonts[name] = (float(size.group(1)), bool(weight) and int(weight.group(1)) >= 600)
    return fonts


def frame_of(svg):
    """The chart's width and height, from its viewBox."""
    box = re.search(r'viewBox="0 0 ([0-9.]+) ([0-9.]+)"', svg)
    return float(box.group(1)), float(box.group(2))


def box_of(text, x, y, anchor, font):
    """The box a text takes: its left, right, top, and bottom."""
    size, bold = font
    width = width_of(text, size, bold)
    left = {"middle": x - width / 2, "end": x - width}.get(anchor, x)
    return left, left + width, y - ascent * size, y + descent * size


def texts_of(svg):
    """Each text of the chart: its words, its box, and its class. No chart turns a text on its side."""
    fonts = fonts_of(svg)
    texts = []
    for attributes, inner in text_pattern.findall(svg):
        values = dict(attribute_pattern.findall(attributes))
        words = html.unescape(re.sub(r"<[^>]+>", "", inner))
        font = fonts.get(values.get("class", ""), (float(values.get("font-size", "16")), False))
        box = box_of(words, float(values["x"]), float(values["y"]), values.get("text-anchor", "start"), font)
        texts.append((words, box, values.get("class", "")))
    return texts


def outside(svg):
    """The words of each text whose box passes an edge of the chart."""
    width, height = frame_of(svg)
    return [
        words
        for words, (left, right, top, bottom), _ in texts_of(svg)
        if left < 0 or right > width or top < 0 or bottom > height
    ]


def overlapping(svg):
    """Each pair of texts whose boxes cross."""
    texts = texts_of(svg)
    return [
        (first[0], second[0])
        for index, first in enumerate(texts)
        for second in texts[index + 1 :]
        if crosses(first[1], second[1])
    ]


def crosses(first, second):
    """Whether two boxes share some area."""
    return first[0] < second[1] and second[0] < first[1] and first[2] < second[3] and second[2] < first[3]


def faults(svg):
    """What a reader would see wrong: each text past an edge, each pair drawn over each other, and
    each text drawn over a bar."""
    found = [f"past an edge: {words}" for words in outside(svg)]
    found += [f"drawn over each other: {first} | {second}" for first, second in overlapping(svg)]
    return found + [f"drawn over a bar: {words}" for words in over_bars(svg)]


def over_bars(svg):
    """The words of each text whose box crosses a bar's."""
    bars = bars_of(svg)
    return [words for words, box, _ in texts_of(svg) if any(crosses(box, bar) for bar in bars)]


def bars_of(svg):
    """The box of each bar: each rect placed on the chart, but the surface behind it all, which has
    no place, and each path of moves, lines, and arcs."""
    bars = []
    for attributes in rect_pattern.findall(svg):
        values = dict(attribute_pattern.findall(attributes))
        if "x" in values:
            left, top = float(values["x"]), float(values["y"])
            bars.append((left, left + float(values["width"]), top, top + float(values["height"])))
    return bars + [box for box in map(path_box, path_pattern.findall(svg)) if box]


def path_box(path):
    """The box of a path drawn as a bar: an absolute move, then relative lines and arcs. Each arc of
    a bar is a quarter circle, which stays inside the box of its two ends. Another path gives None."""
    x = y = 0.0
    points = []
    for command, arguments in command_pattern.findall(path):
        values = [float(number) for number in number_pattern.findall(arguments)]
        if command == "M":
            x, y = values[0], values[1]
        elif command == "h":
            x += values[0]
        elif command == "v":
            y += values[0]
        elif command == "a":
            x, y = x + values[5], y + values[6]
        elif command != "z":
            return None
        points.append((x, y))
    xs, ys = [point[0] for point in points], [point[1] for point in points]
    return (min(xs), max(xs), min(ys), max(ys)) if points else None


def tick_gap(svg):
    """The least distance between the middles of two tick labels on one line, or None when no line
    holds two."""
    lines = {}
    for _, (left, right, _, bottom), kind in texts_of(svg):
        if kind == "tick":
            lines.setdefault(bottom, []).append((left + right) / 2)
    gaps = [later - earlier for middles in lines.values() for earlier, later in itertools.pairwise(sorted(middles))]
    return min(gaps, default=None)


def unexplained_marks(svg, marks):
    """Each mark that a label or the title carries and no line of the subtitle explains, and each one
    the subtitle explains that no label carries. A line explains a mark when it starts with it:
    `≥ marks a climb ...`, or `"slots full" marks ...`."""
    texts = texts_of(svg)
    labels = [words for words, _, kind in texts if kind in ("val", "title")]
    notes = [words for words, _, kind in texts if kind == "sub"]
    found = []
    for mark in marks:
        carried = any(mark in words for words in labels)
        explained = any(words.startswith((f"{mark} marks", f'"{mark}" marks')) for words in notes)
        if carried != explained:
            found.append(f"{mark}: {'carried' if carried else 'explained'} alone")
    return found


# The time GitHub writes before each line of a job's log.
github_stamp = "2026-11-23T23:36:47.3886502Z "


def github_log(text):
    """The text as a log that GitHub wrote: the time before each line."""
    return "\n".join(github_stamp + line for line in text.split("\n"))
