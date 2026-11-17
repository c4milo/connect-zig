#!/usr/bin/env python3
"""Writes a production report of tools/fullstack/production.sh (design §8 steps 29 and 30) on
standard output.

    tools/fullstack/production_report.py <results> <transport> <ticks> <oha> <otelcol> <vector>
                                         <rotel> <commit> <placement> <seconds> <warm> <limit_ms>
                                         <suite> <spans:connections>...

<results> holds a line for each step of each server's climb: "step", the transport, the server,
the exports a connection a second, the spans of the calls answered 200, the measured calls a
second and spans a second, p50 and p99 in milliseconds, the calls refused, the verdict, and the
server's CPU ticks over the step. A line "memory" gives the transport, the server and its peak
memory in KiB. The report holds the lines of <transport> alone, `tls` or `cleartext`. <ticks> is
the ticks of a second of CPU time.
"""
import sys

from machine import machine

results, transport, ticks, oha, otelcol, vector, rotel, commit, placement, seconds, warm, limit_ms, suite = sys.argv[1:14]
ticks, seconds, warm, limit_ms = int(ticks), float(seconds), float(warm), float(limit_ms)
classes = [tuple(int(part) for part in item.split(":")) for item in sys.argv[14:]]
names = {"connect-zig": "connect-zig", "collector": "Collector", "vector": "Vector", "rotel": "Rotel"}
setups = {
    "collector": f"{otelcol}, GOMAXPROCS=1, its OTLP receiver into its nop exporter",
    "vector": f"{vector}, one thread, its opentelemetry source into its blackhole sink",
    "rotel": f"{rotel}, its OTLP receiver into its blackhole exporter",
}
# The fleet the model stands for, and the gateway cores that share its connections.
fleet_servers = 33_000
gateway_cores = 64
microseconds = 1_000_000
kib = 1024
percent = 100

servers, steps, memory = [], {}, {}
for line in open(results):
    fields = line.split()
    if len(fields) < 3 or fields[1] != transport:
        continue
    server = fields[2]
    if server not in servers:
        servers.append(server)
    if fields[0] == "memory":
        memory[server] = int(fields[3]) / kib
        continue
    rate, taken, calls, spans, p50, p99, refused, verdict, cpu = fields[3:12]
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


over = "over TLS" if transport == "tls" else "over cleartext h2"
ended_by = {"refused": "a call refused", "p99": f"p99 past {limit_ms:.0f} ms", "rate": "spans short of the rate"}
print(f"## Full stack, production {over}: one gateway core for {fleet_servers:,} servers")
print()
print(f"Each server holds {connections} connections {over}, as one core of a {gateway_cores}-core gateway tier does")
print(f"when {fleet_servers:,} servers each run a Collector agent. "
      + ", ".join(f"{count} connections send gzip exports of {spans} spans" for spans, count in classes) + ".")
print(f"oha sends at fixed rates with its latency correction, and the rate climbs until p99 passes {limit_ms:.0f} ms or a")
print(f"call is refused. Each step lasts {seconds:.0f} s, and its measure leaves out the first {warm:.0f} s. Every span was checked.")
print()
print("| server | spans/s held | calls/s | p50 ms | p99 ms | core busy | CPU µs a span | peak MiB | the next step |")
print("|---|--:|--:|--:|--:|--:|--:|--:|---|")
best = {}
for server in servers:
    step, verdict = held(server)
    if step is None:
        print(f"| {names[server]} | none | | | | | | | {ended_by.get(verdict, verdict)} |")
        continue
    best[server] = step
    print(f"| {names[server]} | {step['spans']:,.0f} | {step['calls']:,.0f} | {step['p50']:.2f} | {step['p99']:.2f} | "
          f"{step['busy'] * percent:.0f}% | {step['cpu']:.2f} | {memory.get(server, 0):.0f} | "
          f"{ended_by.get(verdict, verdict)} |")
print()
if "connect-zig" in best:
    zig = best["connect-zig"]["spans"]
    for server in servers[1:]:
        if server in best:
            print(f"- connect-zig holds {zig / best[server]['spans']:.2f} times {names[server]}'s spans a second on one core.")
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
