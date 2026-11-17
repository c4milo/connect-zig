#!/usr/bin/env python3
"""Writes the production report of tools/fullstack/production.sh (design §8 step 29) on standard
output.

    tools/fullstack/production_report.py <results> <ticks> <oha> <otelcol> <commit> <placement>
                                         <seconds> <warm> <limit_ms> <suite> <spans:connections>...

<results> holds a line for each step of each server's climb: "step", the server, the exports a
connection a second, the spans of the calls answered 200, the measured calls a second and spans a
second, p50 and p99 in milliseconds, the calls refused, the verdict, and the server's CPU ticks
over the step. A line "memory" gives each server's peak memory in KiB. <ticks> is the ticks of a
second of CPU time.
"""
import sys

from machine import machine

results, ticks, oha, otelcol, commit, placement, seconds, warm, limit_ms, suite = sys.argv[1:11]
ticks, seconds, warm, limit_ms = int(ticks), float(seconds), float(warm), float(limit_ms)
classes = [tuple(int(part) for part in item.split(":")) for item in sys.argv[11:]]
servers = [("connect-zig", "connect-zig"), ("collector", "Collector")]
# The fleet the model stands for, and the gateway cores that share its connections.
fleet_servers = 33_000
gateway_cores = 64
microseconds = 1_000_000
kib = 1024
percent = 100

steps, memory = {}, {}
for line in open(results):
    fields = line.split()
    if fields[0] == "memory":
        memory[fields[1]] = int(fields[2]) / kib
        continue
    _, server, rate, taken, calls, spans, p50, p99, refused, verdict, cpu = fields
    steps.setdefault(server, []).append({
        "rate": float(rate), "taken": int(taken), "calls": float(calls), "spans": float(spans),
        "p50": float(p50), "p99": float(p99), "refused": int(refused), "verdict": verdict,
        "busy": int(cpu) / ticks / seconds, "cpu": int(cpu) * microseconds / ticks / max(int(taken), 1),
    })

connections = sum(count for _, count in classes)
spans_per_rate = sum(spans * count for spans, count in classes)


def held(server):
    """The highest step the server passed, and the verdict of the step after it."""
    passed = [step for step in steps.get(server, []) if step["verdict"] == "pass"]
    failed = [step for step in steps.get(server, []) if step["verdict"] != "pass"]
    return (passed[-1] if passed else None), (failed[0]["verdict"] if failed else "none: the last step passed")


ended_by = {"refused": "a call refused", "p99": f"p99 past {limit_ms:.0f} ms", "rate": "spans short of the rate"}
print(f"## Full stack, production: one gateway core for {fleet_servers:,} servers")
print()
print(f"Each server holds {connections} TLS connections, as one core of a {gateway_cores}-core gateway tier does when")
print(f"{fleet_servers:,} servers each run a Collector agent. "
      + ", ".join(f"{count} connections send gzip exports of {spans} spans" for spans, count in classes) + ".")
print(f"oha sends at fixed rates with its latency correction, and the rate climbs until p99 passes {limit_ms:.0f} ms or a")
print(f"call is refused. Each step lasts {seconds:.0f} s, and its measure leaves out the first {warm:.0f} s. Every span was checked.")
print()
print("| server | spans/s held | calls/s | p50 ms | p99 ms | core busy | CPU µs a span | peak MiB | the next step |")
print("|---|--:|--:|--:|--:|--:|--:|--:|---|")
best = {}
for server, name in servers:
    step, verdict = held(server)
    if step is None:
        print(f"| {name} | none | | | | | | | {ended_by.get(verdict, verdict)} |")
        continue
    best[server] = step
    print(f"| {name} | {step['spans']:,.0f} | {step['calls']:,.0f} | {step['p50']:.2f} | {step['p99']:.2f} | "
          f"{step['busy'] * percent:.0f}% | {step['cpu']:.2f} | {memory.get(server, 0):.0f} | {ended_by.get(verdict, verdict)} |")
print()
if len(best) == len(servers):
    zig, collector = best["connect-zig"]["spans"], best["collector"]["spans"]
    print(f"- connect-zig holds {zig / collector:.2f} times the Collector's spans a second on one core.")
    print(f"- At {gateway_cores} cores, connect-zig carries {zig * gateway_cores / fleet_servers:,.0f} spans a second for each of the "
          f"{fleet_servers:,} servers, and the Collector {collector * gateway_cores / fleet_servers:,.0f}.")
    print()
print("The climb, one row for each step: p99 in milliseconds and the share of its core each server kept busy.")
print()
print("| exports a connection a second | spans/s sent | connect-zig p99 | connect-zig core | Collector p99 | Collector core |")
print("|--:|--:|--:|--:|--:|--:|")
rates = sorted({step["rate"] for server in steps for step in steps[server]})
for rate in rates:
    cells = []
    for server, _ in servers:
        step = next((step for step in steps.get(server, []) if step["rate"] == rate), None)
        if step is None:
            cells += ["", ""]
            continue
        mark = "" if step["verdict"] == "pass" else f" ({step['verdict']})"
        cells += [f"{step['p99']:.2f}{mark}", f"{step['busy'] * percent:.0f}%"]
    print(f"| {rate:g} | {rate * spans_per_rate:,.0f} | " + " | ".join(cells) + " |")
print()
print(f"Machine: {machine()}.")
print(f"Load: {oha}, {suite}; {placement}.")
print(f"Servers: connect-zig {commit} in ReleaseSafe, `tools/otlp_sink`; {otelcol}, GOMAXPROCS=1, the OTLP")
print("receiver into the nop exporter, no processor.")
