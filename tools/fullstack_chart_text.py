"""The words of tools/fullstack_chart.py: its title, its subtitle, and the ratio each bar's label
gives, with the marks a rate that is a floor puts on them.
"""

# Each receiver that validates, and its twin that does not.
twins = {
    "connect-zig + protovalidate": "connect-zig",
    "connect-go + protovalidate-go": "connect-go",
    "connect-rust + protovalidate-buffa": "connect-rust",
}
# The Connect libraries, which the title names when the table holds them (decision 46).
libraries = ("connect-go", "connect-rust")
# The p99 past which a step fails.
limit_ms = 100
# The longest title the chart's width holds at its font: a longer one leaves out the limit, which
# the subtitle states.
title_len_max = 90
# What each mark of a label means. A climb whose every step passed gives no step that failed, so
# its rate is a floor, and a ratio of it is a floor or a ceiling.
mark_lines = {
    "≥": "≥ marks a rate whose climb passed every step, and a ratio of such a rate over another: each is at least its value.",
    "≤": "≤ marks a ratio over a rate whose climb passed every step: the ratio is at most its value.",
    "?": "? marks a ratio of two rates whose climbs passed every step, which neither rate bounds.",
}


def bound(held, top, bottom):
    """How a ratio of two rates held reads: a ratio over a floor is at most its value, a ratio of a
    floor at least, and a ratio of two floors is marked so."""
    if held[top]["floor"] and held[bottom]["floor"]:
        return "?", "about "
    if held[top]["floor"]:
        return "≥", "at least "
    if held[bottom]["floor"]:
        return "≤", "at most "
    return "", ""


def ratio_names(held, name, validate):
    """The two servers whose rates a bar's ratio divides, or None when its label gives no ratio."""
    top, bottom = (name, twins.get(name)) if validate else ("connect-zig", name)
    return None if bottom not in held or top == bottom else (top, bottom)


def bar_ratio(held, name, validate):
    """The end of a bar's label: connect-zig's rate over the server's, or the share kept of its twin's."""
    names = ratio_names(held, name, validate)
    if names is None:
        return ""
    top, bottom = names
    if validate:
        return f", {bound(held, top, bottom)[0]}{held[top]['spans'] / held[bottom]['spans'] * 100:.0f}%"
    return f", connect-zig {bound(held, top, bottom)[0]}{held[top]['spans'] / held[bottom]['spans']:.1f}×"


def marks_of(held, validate):
    """Each mark the bars' labels carry: ≥ on a rate that is a floor, and the mark of each ratio."""
    marks = {"≥"} if any(item["floor"] for item in held.values()) else set()
    for name in held:
        names = ratio_names(held, name, validate)
        if names is not None:
            marks.add(bound(held, *names)[0])
    return marks - {""}


def title_of(held, servers, validate):
    """The chart's title: connect-zig's rate over each other's, or each share protovalidate keeps."""
    if validate:
        kept = [
            f"{twin} {bound(held, name, twin)[0]}{held[name]['spans'] / held[twin]['spans'] * 100:.0f}%"
            for name, twin in twins.items()
            if name in held and twin in held
        ]
        return f"Rate kept with protovalidate: {', '.join(kept)}"
    others = [name for name in servers if name != "connect-zig"]
    # Four ratios do not fit one title, so a table with the Connect libraries names them alone, and
    # each bar gives its own ratio.
    titled = [name for name in others if name in libraries] or others
    ratios = [
        f"{bound(held, 'connect-zig', name)[1]}{held['connect-zig']['spans'] / held[name]['spans']:.1f} times "
        f"{'the ' if name == 'Collector' else ''}{name}'s"
        for name in titled
    ]
    title = f"One core holds {' and '.join(ratios)} spans a second, with p99 under {limit_ms} ms"
    if len(title) > title_len_max:
        title = f"One core holds {' and '.join(ratios)} spans a second"
    return title


def subtitle_of(held, validate, over):
    """The subtitle's lines, which say what a whisker spans when a bar has one, and what each mark of
    a label means when a label carries it."""
    subtitle = [
        f"Each server holds 516 connections {over}, as one core of a 64-core gateway for 33,000 servers, and",
        f"takes gzip OTLP exports of 16, 128 and 512 spans. The rate climbs until p99 passes {limit_ms} ms or a call is refused.",
    ]
    ranges = any("low" in item for item in held.values())
    whiskers = ranges or any(item["gap"] is not None for item in held.values())
    # What a whisker spans: the rates the rounds held, or, in a report of one climb, the gap to the
    # step that failed.
    whisker_text = (
        "Each bar is the median of the rounds, and its whisker spans the rates they held."
        if ranges
        else "A whisker reaches the step that failed, so the rate a core holds lies inside it."
    )
    if validate:
        subtitle.append(
            "Each share is a receiver's spans a second with protovalidate over its own without. A dashed line is a"
        )
        subtitle.append("receiver that validates." + (f" {whisker_text}" if whiskers else ""))
    elif whiskers:
        subtitle.append(whisker_text)
    if ranges:
        subtitle.append("The right panel gives each server's first round, which climbs from the lowest rate.")
    # Each mark a label can carry, explained on a line of its own only when a label carries it.
    marks = marks_of(held, validate)
    subtitle.extend(mark_lines[mark] for mark in ("≥", "≤", "?") if mark in marks)
    return subtitle
