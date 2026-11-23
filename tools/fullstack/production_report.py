#!/usr/bin/env python3
"""Writes a production report of tools/fullstack/production.sh (design §8 steps 29 and 30) on
standard output.

    tools/fullstack/production_report.py <results> <transport> <ticks> <oha> <otelcol> <vector>
                                         <rotel> <connect-go> <connect-rust> <commit> <placement>
                                         <seconds> <warm> <limit_ms> <suite> <spans:connections>...

<results> holds the lines of each server's climb, as tools/fullstack/climb.py reads them. The
report holds the lines of <transport> alone, `tls` or `cleartext`. <ticks> is the ticks of a
second of CPU time.
"""
import sys

import climb
from machine import machine

results, transport, ticks, oha, otelcol, vector, rotel, connect_go, connect_rust, commit, placement, seconds, warm, limit_ms, suite = sys.argv[1:16]
ticks, seconds, warm, limit_ms = int(ticks), float(seconds), float(warm), float(limit_ms)
classes = [tuple(int(part) for part in item.split(":")) for item in sys.argv[16:]]
names = {"connect-zig": "connect-zig", "connect-zig-validate": "connect-zig + protovalidate",
         "collector": "Collector", "vector": "Vector", "rotel": "Rotel", "connect-go": "connect-go",
         "connect-go-validate": "connect-go + protovalidate-go",
         "connect-rust": "connect-rust", "connect-rust-validate": "connect-rust + protovalidate-buffa"}
# Each receiver that validates, and its twin that does not.
validating = [("connect-zig-validate", "connect-zig"), ("connect-go-validate", "connect-go"),
              ("connect-rust-validate", "connect-rust")]
setups = {
    "collector": f"{otelcol}, GOMAXPROCS=1, its OTLP receiver into its nop exporter",
    "vector": f"{vector}, one thread, its opentelemetry source into its blackhole sink",
    "rotel": f"{rotel}, its OTLP receiver into its blackhole exporter",
    "connect-go": f"{connect_go}, GOMAXPROCS=1, a receiver that counts spans (`tools/fullstack/connect-go`)",
    "connect-rust": f"{connect_rust}, one tokio worker, a receiver that counts spans (`tools/fullstack/connect-rust`)",
    "connect-zig-validate": "connect-zig + protovalidate, `otlp-sink-validate`, which checks each export against the rules of `tools/fullstack/validate`",
    "connect-go-validate": "connect-go + protovalidate-go, the same receiver with `validate`, which checks each export against the same rules",
    "connect-rust-validate": "connect-rust + protovalidate-buffa, the same receiver with `validate`, which checks each export against the same rules",
}
# The fleet the model stands for, and the gateway cores that share its connections.
fleet_servers = 33_000
gateway_cores = 64
percent = 100

servers, steps, memory = climb.read(results, transport, ticks, seconds)
connections = sum(count for _, count in classes)
spans_per_rate = sum(spans * count for spans, count in classes)


over = "over TLS" if transport == "tls" else "over cleartext h2"
# What a step's first seconds hold, which its measure leaves out.
starting = "each step's TLS handshakes run" if transport == "tls" else "each step opens its connections"
ended_by = {"refused": "a call refused", "p99": f"p99 past {limit_ms:.0f} ms", "rate": "spans short of the rate"}
print(f"## Full stack, production {over}: one gateway core for {fleet_servers:,} servers")
print()
print(f"Each server holds {connections} connections {over}, as one core of a {gateway_cores}-core gateway tier does")
print(f"when {fleet_servers:,} servers each run a Collector agent. "
      + ", ".join(f"{count} connections send gzip exports of {spans} spans" for spans, count in classes) + ".")
print(f"oha sends at fixed rates with its latency correction, and the rate climbs until p99 passes {limit_ms:.0f} ms or a")
print(f"measured call is refused. Each step lasts {seconds:.0f} s, and its measure leaves out the first {warm:.0f} s, where")
print(f"{starting}. Every span was checked.")
print()
print("The rate a core holds lies between the step it held and the next step, which failed; the resolution gives")
print("that gap as a share of the step held. A server that refuses calls past a fixed count, as connect-zig's sink")
print("does past 64, refuses some calls in those first seconds: the held step's calls refused then.")
print()
print("| server | spans/s held | resolution | calls/s | p50 ms | p99 ms | core busy | CPU µs a span | peak MiB | refused at its start | the next step |")
print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|")


def validation_line(server, twin):
    """What validation costs a receiver: the share of its twin's rate it holds, or that the climb
    cannot tell the two apart, and the CPU a span of each at the highest rate both held."""
    share = best[server]["spans"] / best[twin]["spans"] * percent
    if climb.apart(best[server], above[server], best[twin], above[twin]):
        line = f"{names[server]} holds {share:.0f}% of {twin}'s spans a second"
    else:
        line = f"{names[server]} and {twin} hold rates the climb cannot tell apart ({share:.0f}%)"
    rate = climb.common_rate(steps[server], steps[twin])
    if rate is None:
        return line + "."
    mine, theirs = climb.at(steps[server], rate), climb.at(steps[twin], rate)
    return (line + f". At {rate * spans_per_rate:,.0f} spans a second, which both held, it spends {mine['cpu']:.2f} µs "
            f"of CPU a span to its {theirs['cpu']:.2f}, {(mine['cpu'] / theirs['cpu'] - 1) * percent:+.0f}%.")


best, above = {}, {}
for server in servers:
    step, failed, verdict = climb.held(steps.get(server, []))
    if step is None:
        print(f"| {names[server]} | none | | | | | | | | | {ended_by.get(verdict, verdict)} |")
        continue
    best[server], above[server] = step, failed
    gap = climb.resolution(step, failed)
    print(f"| {names[server]} | {step['spans']:,.0f} | {'' if gap is None else f'+{gap * percent:.1f}%'} | "
          f"{step['calls']:,.0f} | {step['p50']:.2f} | {step['p99']:.2f} | "
          f"{step['busy'] * percent:.0f}% | {step['cpu']:.2f} | {memory.get(server, 0):.0f} | "
          f"{step['warm_refused']:,} | {ended_by.get(verdict, verdict)} |")
print()
if "connect-zig" in best:
    zig = best["connect-zig"]["spans"]
    for server in servers[1:]:
        if server in best and not server.endswith("-validate"):
            print(f"- connect-zig holds {zig / best[server]['spans']:.2f} times {names[server]}'s spans a second on one core.")
    for server, twin in validating:
        if server in best and twin in best:
            print(f"- {validation_line(server, twin)}")
    carried = ", ".join(f"{names[server]} {best[server]['spans'] * gateway_cores / fleet_servers:,.0f}" for server in servers if server in best)
    print(f"- At {gateway_cores} cores, the spans a second each server carries for each of the {fleet_servers:,} servers: {carried}.")
    print()
print("The climb, one row for each step: p99 in milliseconds and the share of its core each server kept busy.")
print()
print("| exports a connection a second | spans/s sent | "
      + " | ".join(f"{names[server]} p99 | {names[server]} core" for server in servers) + " |")
print("|--:|--:|" + "--:|--:|" * len(servers))
rates = sorted({step["rate"] for server in steps for step in steps[server]})
for rate in rates:
    cells = []
    for server in servers:
        step = next((step for step in steps.get(server, []) if step["rate"] == rate), None)
        if step is None:
            cells += ["", ""]
            continue
        mark = "" if step["verdict"] == "pass" else f" ({step['verdict']})"
        cells += [f"{step['p99']:.2f}{mark}", f"{step['busy'] * percent:.0f}%"]
    print(f"| {rate:g} | {rate * spans_per_rate:,.0f} | " + " | ".join(cells) + " |")
print()
print(f"Machine: {machine()}.")
security = f"{suite}; " if transport == "tls" else ""
print(f"Load: {oha}, {security}{placement}.")
print(f"Servers: connect-zig {commit} in ReleaseSafe, `tools/otlp_sink`; "
      + "; ".join(setups[server] for server in servers if server in setups) + ".")
