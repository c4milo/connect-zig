#!/usr/bin/env python3
"""Writes the report of tools/fullstack/compression.sh (design §8 step 37) on standard output.

    tools/fullstack/compression_report.py <work> <transport> <ticks> <h2load> <load> <connect-go>
                                          <connect-rust> <commit> <placement> <rounds> <seconds>
                                          <variants> <limit_ms> <rounds> <suite> <codings>
                                          <spans:connections>...

<work> holds, for each coding of <codings>, a space-separated list:

- compression-peak-<coding>: a line for each round of a server and an export of the peak, as
  tools/fullstack/peak_report.py reads them: the spans, the server, the calls a second, p50 and
  p99 in microseconds, the server's CPU ticks over the measured calls, the measured calls, and
  its peak memory in KiB.
- compression-climb-<coding>: the lines of each server's climb, as tools/fullstack/climb.py reads
  them.

compression-octets holds a line for each class's first variant of its export in each coding: the
spans, the coding, the message's octets, and the octets sent. <ticks> is the ticks of a second of CPU time.

Each receiver's codings compare with the same receiver uncompressed. The climb runs in rounds, and
compares the rate each coding held with the rate uncompressed held in the same round: the median
share of the rounds, with their range. It also compares the CPU a span at the highest rate all
four first rounds held: a span costs less CPU as the rate rises. The peak compares the median of
its rounds, with their spread.
"""

import os
import statistics
import sys
import types

import climb
from machine import machine

servers = ["connect-zig", "connect-go", "connect-rust"]
coding_names = {"identity": "uncompressed", "gzip": "gzip", "zstd": "zstd", "br": "brotli"}
percent = 100
microseconds = 1_000_000
argument_names = [
    "work",
    "transport",
    "ticks",
    "h2load",
    "load_text",
    "connect_go",
    "connect_rust",
    "commit",
    "placement",
    "rounds",
    "seconds",
    "variants",
    "limit_ms",
    "climb_rounds",
    "suite",
    "codings",
]


def parse(arguments):
    """The command line's values by name, each number as a number, and what the report derives
    from them."""
    report = types.SimpleNamespace(**dict(zip(argument_names, arguments[: len(argument_names)], strict=True)))
    report.ticks, report.seconds, report.variants = int(report.ticks), float(report.seconds), int(report.variants)
    report.limit_ms, report.climb_rounds = float(report.limit_ms), int(report.climb_rounds)
    report.codings = report.codings.split()
    report.classes = [tuple(int(part) for part in item.split(":")) for item in arguments[len(argument_names) :]]
    report.coded = report.codings[1:]
    report.over = "over TLS" if report.transport == "tls" else "over cleartext h2"
    report.ended_by = {
        "refused": "a call refused",
        "p99": f"p99 past {report.limit_ms:.0f} ms",
        "rate": "spans short of the rate",
        "load": "the load's cores full",
    }
    report.spans_per_rate = sum(spans * count for spans, count in report.classes)
    return report


def read_peak(report):
    """Each round of the peak, by coding, the export's spans, and the server."""
    rows = {}
    for coding in report.codings:
        with open(os.path.join(report.work, f"compression-peak-{coding}")) as lines:
            for line in lines:
                spans, server, rate, _p50, p99, cpu_ticks, calls, _peak = line.split()
                rows.setdefault((coding, int(spans), server), []).append(
                    {
                        "rate": float(rate),
                        "p99": int(p99) / 1000,
                        "cpu": int(cpu_ticks) * microseconds / report.ticks / int(calls),
                    }
                )
    return rows


def read_climbs(report):
    """Each coding's climbs, each server's steps by `climb.read`."""
    return {
        coding: climb.read(
            os.path.join(report.work, f"compression-climb-{coding}"), report.transport, report.ticks, report.seconds
        )[1]
        for coding in report.codings
    }


def write_octets(report):
    codings = report.codings
    octets = {}
    with open(os.path.join(report.work, "compression-octets")) as lines:
        for line in lines:
            spans, coding, message, sent = line.split()
            octets[(int(spans), coding)] = (int(message), int(sent))
    print("| export | " + " | ".join(coding_names[coding] for coding in codings) + " |")
    print("|---|" + "--:|" * len(codings))
    for spans in sorted({spans for spans, _ in octets}):
        message = octets[(spans, codings[0])][0]
        cells = [
            f"{octets[(spans, coding)][1]:,}"
            + ("" if coding == "identity" else f" ({message / octets[(spans, coding)][1]:.1f}×)")
            for coding in codings
        ]
        print(f"| {spans} spans | " + " | ".join(cells) + " |")
    print()


def coding_shares(server, coding, held):
    """A coding's spans a second as a share of the receiver's uncompressed rate, in each round
    both held a step: each round climbs every coding once, near in time. The median and the
    range, or None."""
    plain = held.get((server, "identity"))
    if plain is None or (server, coding) not in held:
        return None
    ratios = climb.round_ratios(held[(server, coding)], plain)
    return (statistics.median(ratios), min(ratios), max(ratios)) if ratios else None


def held_of(report, climbs):
    """Each receiver's summary of its rounds in each coding, by `climb.summary`, for the codings
    whose rounds held a step."""
    held = {}
    for server in servers:
        for coding in report.codings:
            result, _ = climb.summary(climbs[coding].get(server, []))
            if result is not None:
                held[(server, coding)] = result
    return held


def climb_row(report, climbs, held, server, coding):
    """A row of the climb's table: a receiver's rate held in a coding, and its share of the rate
    held uncompressed."""
    ended_by = report.ended_by
    if (server, coding) not in held:
        verdict = climb.summary(climbs[coding].get(server, []))[1]
        return f"| {server} | {coding_names[coding]} | no step | | | | | | {ended_by.get(verdict, verdict)} |"
    result = held[(server, coding)]
    step, verdict = result["best"], result["verdict"]
    gap = climb.resolution(step, result["above"])
    shares = coding_shares(server, coding, held)
    share = "" if shares is None else f"{shares[0] * percent:.0f}%"
    share_range = (
        "" if shares is None or coding == "identity" else f"{shares[1] * percent:.0f}–{shares[2] * percent:.0f}%"
    )
    return (
        f"| {server} | {coding_names[coding]} | {step['spans']:,.0f} | {result['low']:,.0f}–{result['high']:,.0f} | "
        f"{share} | {share_range} | {'' if gap is None else f'+{gap * percent:.1f}%'} | {step['p99']:.2f} | "
        f"{ended_by.get(verdict, verdict)} |"
    )


def write_climb(report, climbs):
    print("| server | coding | spans/s held | range | share | share range | resolution | p99 ms | the next step |")
    print("|---|---|--:|--:|--:|--:|--:|--:|---|")
    held = held_of(report, climbs)
    for server in servers:
        for coding in report.codings:
            print(climb_row(report, climbs, held, server, coding))
    print()
    for server in servers:
        write_climb_lines(report, climbs, server, held)
    print()


def write_climb_lines(report, climbs, server, held):
    """Each coding's rate as a share of the receiver's uncompressed rate, or that the rounds cannot
    tell the two apart, then each coding's CPU a span at the highest rate every first round
    held."""
    plain = held.get((server, "identity"))
    if plain is None:
        return
    for coding in report.coded:
        shares = coding_shares(server, coding, held)
        if shares is None:
            continue
        share, low, high = (value * percent for value in shares)
        spread = f"{low:.0f}% to {high:.0f}% round by round"
        if low > percent or high < percent:
            bound = climb.bound(held[(server, coding)]["above"], plain["above"])
            print(
                f"- {server} in {coding_names[coding]} holds {bound}{share:.0f}% of its uncompressed spans a second, {spread}."
            )
        else:
            print(
                f"- {server} in {coding_names[coding]} and uncompressed hold rates the rounds cannot tell apart ({share:.0f}%, {spread})."
            )
    first = {coding: climb.first_round(climbs[coding].get(server, [])) for coding in report.codings}
    rate = climb.common_rate(*first.values())
    if rate is None:
        return
    cpu = {coding: climb.at(first[coding], rate)["cpu"] for coding in report.codings}
    costs = ", ".join(
        f"{coding_names[coding]} {cpu[coding]:.2f} ({(cpu[coding] / cpu['identity'] - 1) * percent:+.0f}%)"
        for coding in report.coded
    )
    print(
        f"- {server} at {rate * report.spans_per_rate:,.0f} spans a second, which every coding's first round held, spends µs of CPU a span: "
        f"uncompressed {cpu['identity']:.2f}, {costs}."
    )


def summary(peak, coding, spans, server, key):
    """The median of the rounds, and their least and greatest."""
    values = [row[key] for row in peak.get((coding, spans, server), [])]
    return (statistics.median(values), min(values), max(values)) if values else None


def write_peak(report, peak):
    print("| export | server | coding | calls/s | calls/s range | p99 ms | CPU µs a call |")
    print("|---|---|---|--:|--:|--:|--:|")
    spans_list = sorted({spans for _, spans, _ in peak})
    for spans in spans_list:
        for server in servers:
            for coding in report.codings:
                rate = summary(peak, coding, spans, server, "rate")
                if rate is None:
                    print(f"| {spans} spans | {server} | {coding_names[coding]} | absent | | | |")
                    continue
                print(
                    f"| {spans} spans | {server} | {coding_names[coding]} | {rate[0]:,.0f} | {rate[1]:,.0f}–{rate[2]:,.0f} | "
                    f"{summary(peak, coding, spans, server, 'p99')[0]:.2f} | {summary(peak, coding, spans, server, 'cpu')[0]:.1f} |"
                )
    print()
    for spans in spans_list:
        for server in servers:
            write_peak_line(report, peak, spans, server)
    print()


def write_peak_line(report, peak, spans, server):
    """Each coding's calls a second as a share of uncompressed, marked when the two ranges of the
    rounds overlap."""
    plain = summary(peak, "identity", spans, server, "rate")
    if plain is None:
        return
    shares = []
    for coding in report.coded:
        rate = summary(peak, coding, spans, server, "rate")
        if rate is None:
            continue
        overlap = rate[1] <= plain[2] and plain[1] <= rate[2]
        shares.append(
            f"{coding_names[coding]} {rate[0] / plain[0] * percent:.0f}%" + (" (ranges overlap)" if overlap else "")
        )
    if shares:
        print(f"- {spans} spans, {server}: calls a second as a share of uncompressed: " + ", ".join(shares) + ".")


def write_intro(report):
    over, coded = report.over, report.coded
    print(f"## Full stack, compression {over}: connect-zig, connect-go and connect-rust")
    print()
    print(
        f"Each Connect receiver takes the production model's OTLP exports {over}, uncompressed and in "
        + ", ".join(coding_names[coding] for coding in coded[:-1])
        + f" and {coding_names[coded[-1]]}."
    )
    print(
        "stdx's encoders wrote each export as a connect-zig client places them: gzip at stdx's default level, zstd and"
    )
    print(
        "brotli at level 1. Each receiver decodes with its library's own decoders, at their defaults. A smaller export"
    )
    print(
        f"also costs less {'TLS and HTTP/2' if report.transport == 'tls' else 'HTTP/2'}, so each share is the coding's cost net of what it saves on the wire. No"
    )
    print("OpenTelemetry exporter sends brotli. Every span was checked. The octets of each class's first variant:")
    print()


def write_climb_intro(report):
    connections = sum(count for _, count in report.classes)
    print(f"### The climb {report.over}")
    print()
    print(
        f"Each receiver holds {connections} connections, as one core of a 64-core gateway for 33,000 servers, and the rate"
    )
    print(
        f"climbs until p99 passes {report.limit_ms:.0f} ms or a call is refused. The load keeps its connections open across the"
    )
    print(
        f"climb, and each connection sends its class's {report.variants} variants of the export in turn. Each step lasts {report.seconds:.0f} s, and every"
    )
    print(
        f"call counts. Each receiver runs {report.climb_rounds} rounds of each coding, each on a new process, and each round gives it its"
    )
    print(
        "codings in an order of its own. Its first climb steps up from the lowest rate, and the others search near the rate"
    )
    print(
        "an earlier one held, from a step at half of it. The table gives the round whose rate held is the median, the"
    )
    print("range of the rounds, and the coding's rate as a share of uncompressed in the same round: the median of the")
    print(
        "rounds, and their range. The rate a core holds lies between the step a round held and the step above it that"
    )
    print(
        "failed; the resolution gives that gap as a share of the step held. A step that fails while the load's two cores,"
    )
    print(
        "which the server never runs on, were 90% busy or more ends the round on the load's cores: its rate held is a floor."
    )
    print()


def write_peak_intro(report):
    print(f"### The peak {report.over}")
    print()
    print("h2load sends one export, again and again, on 16 connections of 4 streams, as fast as each receiver")
    print(
        f"answers. Each cell is the median of {report.rounds} rounds, and each round rotates the order of the codings and receivers."
    )
    print()


def write_footer(report, machine_text):
    print(f"Machine: {machine_text}.")
    print(f"Load: {report.h2load} at the peak and {report.load_text} in the climb, {report.placement}.")
    if report.transport == "tls":
        # Both loads offer the one suite: h2load by its option, and the climb's load alone.
        chosen = climb.suites(os.path.join(report.work, "compression-climb-identity"), report.transport)
        print(
            f"TLS: both loads offer AES-128-GCM alone, {report.suite} in TLS 1.3"
            + (
                ", and each receiver's connections in the climb ran "
                + ", ".join(f"{server} {chosen[server]}" for server in servers if server in chosen)
                if chosen
                else ""
            )
            + "."
        )
    print(
        f"Servers: connect-zig {report.commit} in ReleaseSafe, `otlp-sink-compression`, which holds more calls at once than the other parts' sink, "
        f"on stdx's decoders; {report.connect_go}, GOMAXPROCS=1, "
        f"on compress/gzip, klauspost/compress and andybalholm/brotli; {report.connect_rust}, one tokio worker, on flate2, zstd "
        "and brotli (`tools/fullstack/connect-go`, `tools/fullstack/connect-rust`)."
    )


def write(report, machine_text):
    """The whole report, on standard output."""
    climbs = read_climbs(report)
    peak = read_peak(report)
    write_intro(report)
    write_octets(report)
    write_climb_intro(report)
    write_climb(report, climbs)
    write_peak_intro(report)
    write_peak(report, peak)
    write_footer(report, machine_text)


def main():
    write(parse(sys.argv[1:]), machine())


if __name__ == "__main__":
    main()
