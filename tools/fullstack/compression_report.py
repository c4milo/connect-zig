#!/usr/bin/env python3
"""Writes the report of tools/fullstack/compression.sh (design §8 step 37) on standard output.

    tools/fullstack/compression_report.py <work> <transport> <ticks> <h2load> <load> <connect-go>
                                          <connect-rust> <commit> <placement> <rounds> <seconds>
                                          <variants> <limit_ms> <suite> <codings>
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

Each receiver's codings compare with the same receiver uncompressed. The climb compares the rate
each held, with the climb's resolution, and the CPU a span at the highest rate all four held: a
span costs less CPU as the rate rises. The peak compares the median of the rounds, with their
spread.
"""
import os
import statistics
import sys

import climb
from machine import machine

(work, transport, ticks, h2load, load_text, connect_go, connect_rust, commit, placement, rounds, seconds,
 variants, limit_ms, suite, codings) = sys.argv[1:16]
ticks, seconds, variants, limit_ms = int(ticks), float(seconds), int(variants), float(limit_ms)
codings = codings.split()
classes = [tuple(int(part) for part in item.split(":")) for item in sys.argv[16:]]
servers = ["connect-zig", "connect-go", "connect-rust"]
coding_names = {"identity": "uncompressed", "gzip": "gzip", "zstd": "zstd", "br": "brotli"}
coded = codings[1:]
percent = 100
microseconds = 1_000_000
over = "over TLS" if transport == "tls" else "over cleartext h2"
ended_by = {"refused": "a call refused", "p99": f"p99 past {limit_ms:.0f} ms", "rate": "spans short of the rate",
            "load": "the load's cores full"}
spans_per_rate = sum(spans * count for spans, count in classes)


def read_peak():
    rows = {}
    for coding in codings:
        for line in open(os.path.join(work, f"compression-peak-{coding}")):
            spans, server, rate, p50, p99, cpu_ticks, calls, peak = line.split()
            rows.setdefault((coding, int(spans), server), []).append({
                "rate": float(rate), "p99": int(p99) / 1000,
                "cpu": int(cpu_ticks) * microseconds / ticks / int(calls),
            })
    return rows


def write_octets():
    octets = {}
    for line in open(os.path.join(work, "compression-octets")):
        spans, coding, message, sent = line.split()
        octets[(int(spans), coding)] = (int(message), int(sent))
    print("| export | " + " | ".join(coding_names[coding] for coding in codings) + " |")
    print("|---|" + "--:|" * len(codings))
    for spans in sorted({spans for spans, _ in octets}):
        message = octets[(spans, codings[0])][0]
        cells = [f"{octets[(spans, coding)][1]:,}" + ("" if coding == "identity" else
                 f" ({message / octets[(spans, coding)][1]:.1f}×)") for coding in codings]
        print(f"| {spans} spans | " + " | ".join(cells) + " |")
    print()


climbs = {coding: climb.read(os.path.join(work, f"compression-climb-{coding}"), transport, ticks, seconds)[1]
          for coding in codings}


def write_climb():
    print("| server | coding | spans/s held | resolution | p99 ms | the next step |")
    print("|---|---|--:|--:|--:|---|")
    held = {}
    for server in servers:
        for coding in codings:
            step, above, verdict = climb.held(climbs[coding].get(server, []))
            if step is None:
                print(f"| {server} | {coding_names[coding]} | no step | | | {ended_by.get(verdict, verdict)} |")
                continue
            held[(server, coding)] = (step, above)
            gap = climb.resolution(step, above)
            print(f"| {server} | {coding_names[coding]} | {step['spans']:,.0f} | "
                  f"{'' if gap is None else f'+{gap * percent:.1f}%'} | {step['p99']:.2f} | "
                  f"{ended_by.get(verdict, verdict)} |")
    print()
    for server in servers:
        write_climb_lines(server, held)
    print()


def write_climb_lines(server, held):
    """Each coding's rate as a share of the receiver's uncompressed rate, or that the climb cannot
    tell the two apart, then each coding's CPU a span at the highest rate all held."""
    plain = held.get((server, "identity"))
    if plain is None:
        return
    for coding in coded:
        if (server, coding) not in held:
            continue
        step, above = held[(server, coding)]
        share = step["spans"] / plain[0]["spans"] * percent
        if climb.apart(step, above, *plain):
            print(f"- {server} in {coding_names[coding]} holds {climb.bound(above, plain[1])}{share:.0f}% of its uncompressed "
                  "spans a second.")
        else:
            print(f"- {server} in {coding_names[coding]} and uncompressed hold rates the climb cannot tell apart ({share:.0f}%).")
    rate = climb.common_rate(*(climbs[coding].get(server, []) for coding in codings))
    if rate is None:
        return
    cpu = {coding: climb.at(climbs[coding][server], rate)["cpu"] for coding in codings}
    costs = ", ".join(f"{coding_names[coding]} {cpu[coding]:.2f} ({(cpu[coding] / cpu['identity'] - 1) * percent:+.0f}%)"
                      for coding in coded)
    print(f"- {server} at {rate * spans_per_rate:,.0f} spans a second, which all four held, spends µs of CPU a span: "
          f"uncompressed {cpu['identity']:.2f}, {costs}.")


peak = read_peak()


def summary(coding, spans, server, key):
    """The median of the rounds, and their least and greatest."""
    values = [row[key] for row in peak.get((coding, spans, server), [])]
    return (statistics.median(values), min(values), max(values)) if values else None


def write_peak():
    print("| export | server | coding | calls/s | calls/s range | p99 ms | CPU µs a call |")
    print("|---|---|---|--:|--:|--:|--:|")
    spans_list = sorted({spans for _, spans, _ in peak})
    for spans in spans_list:
        for server in servers:
            for coding in codings:
                rate = summary(coding, spans, server, "rate")
                if rate is None:
                    print(f"| {spans} spans | {server} | {coding_names[coding]} | absent | | | |")
                    continue
                print(f"| {spans} spans | {server} | {coding_names[coding]} | {rate[0]:,.0f} | {rate[1]:,.0f}–{rate[2]:,.0f} | "
                      f"{summary(coding, spans, server, 'p99')[0]:.2f} | {summary(coding, spans, server, 'cpu')[0]:.1f} |")
    print()
    for spans in spans_list:
        for server in servers:
            write_peak_line(spans, server)
    print()


def write_peak_line(spans, server):
    """Each coding's calls a second as a share of uncompressed, marked when the two ranges of the
    rounds overlap."""
    plain = summary("identity", spans, server, "rate")
    if plain is None:
        return
    shares = []
    for coding in coded:
        rate = summary(coding, spans, server, "rate")
        if rate is None:
            continue
        overlap = rate[1] <= plain[2] and plain[1] <= rate[2]
        shares.append(f"{coding_names[coding]} {rate[0] / plain[0] * percent:.0f}%" + (" (ranges overlap)" if overlap else ""))
    if shares:
        print(f"- {spans} spans, {server}: calls a second as a share of uncompressed: " + ", ".join(shares) + ".")


connections = sum(count for _, count in classes)
print(f"## Full stack, compression {over}: connect-zig, connect-go and connect-rust")
print()
print(f"Each Connect receiver takes the production model's OTLP exports {over}, uncompressed and in "
      + ", ".join(coding_names[coding] for coding in coded[:-1]) + f" and {coding_names[coded[-1]]}.")
print("stdx's encoders wrote each export as a connect-zig client places them: gzip at stdx's default level, zstd and")
print("brotli at level 1. Each receiver decodes with its library's own decoders, at their defaults. A smaller export")
print(f"also costs less {'TLS and HTTP/2' if transport == 'tls' else 'HTTP/2'}, so each share is the coding's cost net of what it saves on the wire. No")
print("OpenTelemetry exporter sends brotli. Every span was checked. The octets of each class's first variant:")
print()
write_octets()
print(f"### The climb {over}")
print()
print(f"Each receiver holds {connections} connections, as one core of a 64-core gateway for 33,000 servers, and the rate")
print(f"climbs until p99 passes {limit_ms:.0f} ms or a call is refused. The load keeps its connections open across the")
print(f"climb, and each connection sends its class's {variants} variants of the export in turn. Each step lasts {seconds:.0f} s, and every")
print("call counts. The rate a core holds lies between the step it held and the next step, which failed; the")
print("resolution gives that gap as a share of the step held. A step that fails while the load's two cores, which the")
print("server never runs on, were 90% busy or more ends the climb on the load's cores: the rate held is a floor.")
print()
write_climb()
print(f"### The peak {over}")
print()
print("h2load sends one export, again and again, on 16 connections of 4 streams, as fast as each receiver")
print(f"answers. Each cell is the median of {rounds} rounds, and each round rotates the order of the codings and receivers.")
print()
write_peak()
print(f"Machine: {machine()}.")
print(f"Load: {h2load} at the peak and {load_text} in the climb, {placement}.")
if transport == "tls":
    # Both loads offer the one suite: h2load by its option, and the climb's load alone.
    chosen = climb.suites(os.path.join(work, "compression-climb-identity"), transport)
    print(f"TLS 1.3 suite: both loads offer {suite} alone" + (", and each receiver's connections in the climb ran "
          + ", ".join(f"{server} {chosen[server]}" for server in servers if server in chosen) if chosen else "") + ".")
print(f"Servers: connect-zig {commit} in ReleaseSafe, `otlp-sink-compression`, which holds more calls at once than the other parts' sink, "
      f"on stdx's decoders; {connect_go}, GOMAXPROCS=1, "
      f"on compress/gzip, klauspost/compress and andybalholm/brotli; {connect_rust}, one tokio worker, on flate2, zstd "
      "and brotli (`tools/fullstack/connect-go`, `tools/fullstack/connect-rust`).")
