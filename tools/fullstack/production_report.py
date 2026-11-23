#!/usr/bin/env python3
"""Writes a production report of tools/fullstack/production.sh (design §8 steps 29 and 30) on
standard output.

    tools/fullstack/production_report.py <results> <transport> <ticks> <load> <otelcol> <vector>
                                         <rotel> <connect-go> <connect-rust> <commit> <placement>
                                         <seconds> <variants> <limit_ms> <rounds> <confirm_seconds>
                                         <spans:connections>...

<results> holds the lines of each server's climb, as tools/fullstack/climb.py reads them. The
report holds the lines of <transport> alone, `tls` or `cleartext`. <ticks> is the ticks of a
second of CPU time.
"""
import sys

import climb
from machine import machine

(results, transport, ticks, load_text, otelcol, vector, rotel, connect_go, connect_rust, commit, placement, seconds, variants,
 limit_ms, round_count, confirm_seconds) = sys.argv[1:17]
ticks, seconds, variants, limit_ms = int(ticks), float(seconds), int(variants), float(limit_ms)
round_count, confirm_seconds = int(round_count), float(confirm_seconds)
classes = [tuple(int(part) for part in item.split(":")) for item in sys.argv[17:]]
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
# A p99 an interactive caller would accept, beside the limit of the climb: the report gives the
# rate each server held under it too.
low_limit_ms = 10
# The fleet the model stands for, and the gateway cores that share its connections.
fleet_servers = 33_000
gateway_cores = 64
percent = 100

servers, steps, memory = climb.read(results, transport, ticks, seconds)
connections = sum(count for _, count in classes)
spans_per_rate = sum(spans * count for spans, count in classes)


over = "over TLS" if transport == "tls" else "over cleartext h2"
ended_by = {"refused": "a call refused", "p99": f"p99 past {limit_ms:.0f} ms", "rate": "spans short of the rate",
            "load": "the load's cores full"}
print(f"## Full stack, production {over}: one gateway core for {fleet_servers:,} servers")
print()
print(f"Each server holds {connections} connections {over}, as one core of a {gateway_cores}-core gateway tier does")
print(f"when {fleet_servers:,} servers each run a Collector agent. "
      + ", ".join(f"{count} connections send gzip exports of {spans} spans" for spans, count in classes) + ".")
print("The load sends at fixed rates, each connection on a schedule of its own, and counts each call's latency from")
print("the instant its schedule set, so a call that waits in a queue counts its wait. It keeps its connections open")
print(f"across the climb, as the agents keep theirs, and each connection sends its class's {variants} variants of the export in")
print(f"turn. The rate climbs until p99 passes {limit_ms:.0f} ms or a call is refused. Each step lasts {seconds:.0f} s, and every")
print("call and every span counts.")
print()
print(f"Each server runs {round_count} rounds, each on a new process. The first climbs from the lowest rate, and each")
print("later round searches near the rate the first held, from a step at half of it. The rate a core holds lies")
print("between the step a round held and the step above it that failed; the resolution gives that gap as a share")
print("of the step held. The table gives the round whose rate held is the median, and the range of the rates the")
print("rounds held. The load runs on two cores of its own, which the server never runs on. A step that fails while")
print("they were 90% busy or more ends the round on the load's cores, and its rate held is then a floor, with no")
print("resolution. \"load busy\" is their share at the step held: all their work, the kernel's for the traffic the")
print(f"load sends included. \"p99 ≤ {low_limit_ms} ms\" gives the most spans a second a step of the first round held with")
print(f"p99 at most {low_limit_ms} ms.")
print()
print(f"| server | spans/s held | range | resolution | calls/s | p50 ms | p99 ms | core busy | load busy | CPU µs a span | peak MiB | p99 ≤ {low_limit_ms} ms | the next step |")
print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|")


def validation_line(server, twin):
    """What validation costs a receiver: the share of its twin's rate it holds, or that the rounds
    cannot tell the two apart, and the CPU a span of each at the highest rate both first rounds
    held."""
    share = best[server]["spans"] / best[twin]["spans"] * percent
    ratios = climb.round_ratios(held[server], held[twin])
    spread = f", {min(ratios) * percent:.0f}% to {max(ratios) * percent:.0f}% round by round" if ratios else ""
    if not climb.overlap(held[server], held[twin]):
        line = f"{names[server]} holds {climb.bound(above[server], above[twin])}{share:.0f}% of {twin}'s spans a second{spread}"
    else:
        line = f"{names[server]} and {twin} hold rates the rounds cannot tell apart ({share:.0f}%{spread})"
    mine_steps, theirs_steps = climb.first_round(steps[server]), climb.first_round(steps[twin])
    rate = climb.common_rate(mine_steps, theirs_steps)
    if rate is None:
        return line + "."
    mine, theirs = climb.at(mine_steps, rate), climb.at(theirs_steps, rate)
    return (line + f". At {rate * spans_per_rate:,.0f} spans a second, which both held, it spends {mine['cpu']:.2f} µs "
            f"of CPU a span to its {theirs['cpu']:.2f}, {(mine['cpu'] / theirs['cpu'] - 1) * percent:+.0f}%.")


held, best, above = {}, {}, {}
for server in servers:
    result, verdict = climb.summary(steps.get(server, []))
    if result is None:
        print(f"| {names[server]} | none | | | | | | | | | | | {ended_by.get(verdict, verdict)} |")
        continue
    held[server], best[server], above[server] = result, result["best"], result["above"]
    step = result["best"]
    gap = climb.resolution(step, result["above"])
    # A run with no core pinned measures no load's share.
    load = "" if step["load"] < 0 else f"{step['load'] * percent:.0f}%"
    quick = climb.low_latency(steps[server], low_limit_ms)
    quick_text = "" if quick is None else f"{quick['spans']:,.0f}"
    print(f"| {names[server]} | {step['spans']:,.0f} | {result['low']:,.0f}–{result['high']:,.0f} | "
          f"{'' if gap is None else f'+{gap * percent:.1f}%'} | "
          f"{step['calls']:,.0f} | {step['p50']:.2f} | {step['p99']:.2f} | "
          f"{step['busy'] * percent:.0f}% | {load} | "
          f"{step['cpu']:.2f} | {memory.get(server, 0):.0f} | {quick_text} | "
          f"{ended_by.get(verdict, verdict)} |")
print()
# A server that closed connections under load: the load opened them again before its next step.
closed = [(server, sum(step["reopened"] for step in steps.get(server, []))) for server in servers]
for server, reopened in closed:
    if reopened:
        print(f"- {names[server]} closed connections: the load opened {reopened:,} again over its rounds.")
if any(reopened for _, reopened in closed) and "connect-zig" not in best:
    print()

if "connect-zig" in best:
    zig = held["connect-zig"]
    for server in servers[1:]:
        if server in best and not server.endswith("-validate"):
            ratios = climb.round_ratios(zig, held[server])
            spread = f", {min(ratios):.2f} to {max(ratios):.2f} times round by round" if ratios else ""
            print(f"- connect-zig holds {climb.bound(above['connect-zig'], above[server])}{zig['best']['spans'] / held[server]['best']['spans']:.2f} times "
                  f"{names[server]}'s spans a second on one core{spread}.")
    for server, twin in validating:
        if server in best and twin in best:
            print(f"- {validation_line(server, twin)}")
    carried = ", ".join(f"{names[server]} {best[server]['spans'] * gateway_cores / fleet_servers:,.0f}" for server in servers if server in best)
    print(f"- At {gateway_cores} cores, the spans a second each server carries for each of the {fleet_servers:,} servers: {carried}.")
    print()
# The long step of each server after its rounds: the step at the median rate held, the one with
# the most spans a second, and not the step at half of it before.
confirms = climb.read(results, transport, ticks, seconds, "confirm")[1]
if confirms:
    print(f"Each server then ran one step of {confirm_seconds:.0f} s at the median rate its rounds held, on a new process, after a step")
    print("at half of it.")
    print()
    print("| server | spans/s sent | spans/s taken | p99 ms | core busy | the step |")
    print("|---|--:|--:|--:|--:|---|")
    for server in servers:
        if server not in confirms:
            continue
        step = max(confirms[server], key=lambda item: item["rate"])
        print(f"| {names[server]} | {step['rate'] * spans_per_rate:,.0f} | {step['spans']:,.0f} | {step['p99']:.2f} | "
              f"{step['busy'] * percent:.0f}% | {'held' if step['verdict'] == 'pass' else ended_by.get(step['verdict'], step['verdict'])} |")
    print()
print("The first round's climb, one row for each step: p99 in milliseconds and the share of its core each server kept")
print("busy.")
print()
print("| exports a connection a second | spans/s sent | "
      + " | ".join(f"{names[server]} p99 | {names[server]} core" for server in servers) + " |")
print("|--:|--:|" + "--:|--:|" * len(servers))
first = {server: climb.first_round(steps.get(server, [])) for server in servers}
rates = sorted({step["rate"] for server in servers for step in first[server]})
for rate in rates:
    cells = []
    for server in servers:
        step = climb.at(first[server], rate)
        if step is None:
            cells += ["", ""]
            continue
        mark = "" if step["verdict"] == "pass" else f" ({step['verdict']})"
        cells += [f"{step['p99']:.2f}{mark}", f"{step['busy'] * percent:.0f}%"]
    print(f"| {rate:g} | {rate * spans_per_rate:,.0f} | " + " | ".join(cells) + " |")
print()
print(f"Machine: {machine()}.")
print(f"Load: {load_text}, {placement}.")
chosen = climb.suites(results, transport)
if chosen:
    print("TLS 1.3 suites: the load offers TLS_AES_128_GCM_SHA256 alone, and each server's connections ran "
          + ", ".join(f"{names.get(server, server)} {chosen[server]}" for server in servers if server in chosen) + ".")
print(f"Servers: connect-zig {commit} in ReleaseSafe, `tools/otlp_sink`; "
      + "; ".join(setups[server] for server in servers if server in setups) + ".")
