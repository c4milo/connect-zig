#!/usr/bin/env python3
"""Writes the report of tools/fullstack/compression.sh (design §8 step 37) on standard output.

    tools/fullstack/compression_report.py <work> <transport> <ticks> <h2load> <oha> <connect-go>
                                          <connect-rust> <commit> <placement> <rounds> <seconds>
                                          <limit_ms> <suite> <codings> <spans:connections>...

<work> holds, for each coding of <codings>, a space-separated list:

- compression-peak-<coding>: a line for each round of a server and an export of the peak, as
  tools/fullstack/peak_report.py reads them: the spans, the server, the calls a second, p50 and
  p99 in microseconds, the server's CPU ticks over the measured calls, the measured calls, and
  its peak memory in KiB.
- compression-climb-<coding>: the lines of each server's climb, as
  tools/fullstack/production_report.py reads them.

compression-octets holds a line for each export in each coding: the load, the spans, the coding,
the message's octets, and the octets sent. <ticks> is the ticks of a second of CPU time. Each cell
of the peak is the median of the rounds, taken for each measure alone.
"""
import os
import statistics
import sys

from machine import machine

(work, transport, ticks, h2load, oha, connect_go, connect_rust, commit, placement, rounds, seconds,
 limit_ms, suite, codings) = sys.argv[1:15]
ticks, seconds, limit_ms = int(ticks), float(seconds), float(limit_ms)
codings = codings.split()
classes = [tuple(int(part) for part in item.split(":")) for item in sys.argv[15:]]
servers = ["connect-zig", "connect-go", "connect-rust"]
coding_names = {"identity": "none", "gzip": "gzip", "zstd": "zstd", "br": "brotli"}
percent = 100
microseconds = 1_000_000
kib = 1024
over = "over TLS" if transport == "tls" else "over cleartext h2"
ended_by = {"refused": "a call refused", "p99": f"p99 past {limit_ms:.0f} ms", "rate": "spans short of the rate"}


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


def read_climb(coding):
    steps = {}
    for line in open(os.path.join(work, f"compression-climb-{coding}")):
        fields = line.split()
        if fields[0] != "step" or fields[1] != transport:
            continue
        rate, taken, calls, spans, p50, p99, refused, verdict, cpu = fields[3:12]
        steps.setdefault(fields[2], []).append({
            "rate": float(rate), "spans": float(spans), "p99": float(p99), "verdict": verdict,
            "cpu": int(cpu) * microseconds / ticks / max(int(taken), 1),
        })
    return steps


def held(steps):
    """The highest step passed, and the verdict of the lowest step above it that failed, as
    tools/fullstack/production_report.py takes them."""
    passed = [step for step in steps if step["verdict"] == "pass"]
    best = max(passed, key=lambda step: step["rate"]) if passed else None
    floor = best["rate"] if best else 0
    failed = [step for step in steps if step["verdict"] != "pass" and step["rate"] > floor]
    return best, min(failed, key=lambda step: step["rate"])["verdict"] if failed else "none: the last step passed"


octets = {}
for line in open(os.path.join(work, "compression-octets")):
    load, spans, coding, message, sent = line.split()
    octets[(load, int(spans), coding)] = (int(message), int(sent))

print(f"## Full stack, compression {over}: connect-zig, connect-go and connect-rust")
print()
coded = [coding_names[coding] for coding in codings if coding != "identity"]
print(f"Each Connect receiver takes OTLP exports {over} in no coding, and in "
      + ", ".join(coded[:-1]) + f" and {coded[-1]},")
print("which stdx's encoders wrote as a connect-zig client places them: gzip at stdx's default level, zstd and")
print("brotli at level 1. Every span was checked. The octets of each export:")
print()
print("| export | " + " | ".join(coding_names[coding] for coding in codings) + " |")
print("|---|" + "--:|" * len(codings))
for load, spans in sorted({(load, spans) for load, spans, _ in octets}, key=lambda item: (item[0] != "peak", item[1])):
    message = octets[(load, spans, codings[0])][0]
    cells = [f"{octets[(load, spans, coding)][1]:,}" + ("" if coding == "identity" else
             f" ({message / octets[(load, spans, coding)][1]:.1f}×)") for coding in codings]
    print(f"| {load}, {spans} spans | " + " | ".join(cells) + " |")
print()

connections = sum(count for _, count in classes)
print(f"### The climb {over}")
print()
print(f"Each receiver holds {connections} connections, as one core of a 64-core gateway for 33,000 servers, and the rate")
print(f"climbs until p99 passes {limit_ms:.0f} ms or a call is refused. Each step lasts {seconds:.0f} s.")
print()
print("| server | coding | spans/s held | p99 ms | CPU µs a span | the next step |")
print("|---|---|--:|--:|--:|---|")
best = {}
for server in servers:
    for coding in codings:
        step, verdict = held(read_climb(coding).get(server, []))
        if step is None:
            print(f"| {server} | {coding_names[coding]} | none | | | {ended_by.get(verdict, verdict)} |")
            continue
        best[(server, coding)] = step
        print(f"| {server} | {coding_names[coding]} | {step['spans']:,.0f} | {step['p99']:.2f} | {step['cpu']:.2f} | "
              f"{ended_by.get(verdict, verdict)} |")
print()
for server in servers:
    plain = best.get((server, "identity"))
    for coding in codings[1:]:
        coded = best.get((server, coding))
        if plain and coded:
            print(f"- {server} in {coding_names[coding]} holds {coded['spans'] / plain['spans'] * percent:.1f}% of its spans a second "
                  f"in no coding, and spends {coded['cpu'] - plain['cpu']:+.2f} µs of CPU a span.")
for coding in codings:
    zig = best.get(("connect-zig", coding))
    for server in servers[1:]:
        other = best.get((server, coding))
        if zig and other:
            phrase = "With no coding" if coding == "identity" else f"In {coding_names[coding]}"
            print(f"- {phrase}, connect-zig holds {zig['spans'] / other['spans']:.2f} times {server}'s spans a second.")
print()

peak = read_peak()


def median(coding, spans, server, key):
    values = [row[key] for row in peak.get((coding, spans, server), [])]
    return statistics.median(values) if values else None


print(f"### The peak {over}")
print()
print("h2load sends one export, again and again, on 16 connections of 4 streams, as fast as each receiver")
print(f"answers. Each cell is the median of {rounds} rounds.")
print()
print("| export | server | coding | calls/s | p99 ms | CPU µs a call |")
print("|---|---|---|--:|--:|--:|")
spans_list = sorted({spans for _, spans, _ in peak})
for spans in spans_list:
    for server in servers:
        for coding in codings:
            if median(coding, spans, server, "rate") is None:
                print(f"| {spans} spans | {server} | {coding_names[coding]} | absent | | |")
                continue
            print(f"| {spans} spans | {server} | {coding_names[coding]} | {median(coding, spans, server, 'rate'):,.0f} | "
                  f"{median(coding, spans, server, 'p99'):.2f} | {median(coding, spans, server, 'cpu'):.1f} |")
print()
for spans in spans_list:
    for server in servers:
        plain = median("identity", spans, server, "cpu")
        costs = [f"{coding_names[coding]} {median(coding, spans, server, 'cpu') - plain:+.1f} µs"
                 for coding in codings[1:] if plain is not None and median(coding, spans, server, "cpu") is not None]
        if costs:
            print(f"- {spans} spans, {server}: CPU a call beside no coding: " + ", ".join(costs) + ".")
print()
print(f"Machine: {machine()}.")
security = f"{suite}; " if transport == "tls" else ""
print(f"Load: {h2load} and {oha}, {security}{placement}.")
print(f"Servers: connect-zig {commit} in ReleaseSafe, `tools/otlp_sink`, on stdx's decoders; {connect_go}, GOMAXPROCS=1, "
      f"on compress/gzip, klauspost/compress and andybalholm/brotli; {connect_rust}, one tokio worker, on flate2, zstd "
      "and brotli (`tools/fullstack/connect-go`, `tools/fullstack/connect-rust`).")
