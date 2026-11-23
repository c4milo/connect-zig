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
import types

import climb
from machine import machine

names = {
    "connect-zig": "connect-zig",
    "connect-zig-validate": "connect-zig + protovalidate",
    "collector": "Collector",
    "vector": "Vector",
    "rotel": "Rotel",
    "connect-go": "connect-go",
    "connect-go-validate": "connect-go + protovalidate-go",
    "connect-rust": "connect-rust",
    "connect-rust-validate": "connect-rust + protovalidate-buffa",
}
# Each receiver that validates, and its twin that does not.
validating = [
    ("connect-zig-validate", "connect-zig"),
    ("connect-go-validate", "connect-go"),
    ("connect-rust-validate", "connect-rust"),
]
# A p99 an interactive caller would accept, beside the limit of the climb: the report gives the
# rate each server held under it too.
low_limit_ms = 10
# The fleet the model stands for, and the gateway cores that share its connections.
fleet_servers = 33_000
gateway_cores = 64
percent = 100
argument_names = [
    "results",
    "transport",
    "ticks",
    "load_text",
    "otelcol",
    "vector",
    "rotel",
    "connect_go",
    "connect_rust",
    "commit",
    "placement",
    "seconds",
    "variants",
    "limit_ms",
    "round_count",
    "confirm_seconds",
]


def parse(arguments):
    """The command line's values by name, each number as a number, and what the report derives
    from them."""
    report = types.SimpleNamespace(**dict(zip(argument_names, arguments[: len(argument_names)], strict=True)))
    report.ticks, report.seconds = int(report.ticks), float(report.seconds)
    report.variants, report.limit_ms = int(report.variants), float(report.limit_ms)
    report.round_count, report.confirm_seconds = int(report.round_count), float(report.confirm_seconds)
    report.classes = [tuple(int(part) for part in item.split(":")) for item in arguments[len(argument_names) :]]
    report.connections = sum(count for _, count in report.classes)
    report.spans_per_rate = sum(spans * count for spans, count in report.classes)
    report.over = "over TLS" if report.transport == "tls" else "over cleartext h2"
    report.ended_by = {
        "refused": "a call refused",
        "p99": f"p99 past {report.limit_ms:.0f} ms",
        "rate": "spans short of the rate",
        "load": "the load's cores full",
    }
    return report


def setups(report):
    """How each server other than connect-zig runs, as the report's last line names it."""
    return {
        "collector": f"{report.otelcol}, GOMAXPROCS=1, its OTLP receiver into its nop exporter",
        "vector": f"{report.vector}, one thread, its opentelemetry source into its blackhole sink",
        "rotel": f"{report.rotel}, its OTLP receiver into its blackhole exporter",
        "connect-go": f"{report.connect_go}, GOMAXPROCS=1, a receiver that counts spans (`tools/fullstack/connect-go`)",
        "connect-rust": f"{report.connect_rust}, one tokio worker, a receiver that counts spans (`tools/fullstack/connect-rust`)",
        "connect-zig-validate": "connect-zig + protovalidate, `otlp-sink-validate`, which checks each export against the rules of `tools/fullstack/validate`",
        "connect-go-validate": "connect-go + protovalidate-go, the same receiver with `validate`, which checks each export against the same rules",
        "connect-rust-validate": "connect-rust + protovalidate-buffa, the same receiver with `validate`, which checks each export against the same rules",
    }


def write_intro(report):
    over, limit_ms = report.over, report.limit_ms
    print(f"## Full stack, production {over}: one gateway core for {fleet_servers:,} servers")
    print()
    print(
        f"Each server holds {report.connections} connections {over}, as one core of a {gateway_cores}-core gateway tier does"
    )
    print(
        f"when {fleet_servers:,} servers each run a Collector agent. "
        + ", ".join(f"{count} connections send gzip exports of {spans} spans" for spans, count in report.classes)
        + "."
    )
    print(
        "The load sends at fixed rates, each connection on a schedule of its own, and counts each call's latency from"
    )
    print(
        "the instant its schedule set, so a call that waits in a queue counts its wait. It keeps its connections open"
    )
    print(
        f"across the climb, as the agents keep theirs, and each connection sends its class's {report.variants} variants of the export in"
    )
    print(
        f"turn. The rate climbs until p99 passes {limit_ms:.0f} ms or a call is refused. Each step lasts {report.seconds:.0f} s, and every"
    )
    print("call and every span counts.")
    print()
    print(
        f"Each server runs {report.round_count} rounds, each on a new process. The first climbs from the lowest rate, and each"
    )
    print("later round searches near the rate the first held, from a step at half of it. The rate a core holds lies")
    print("between the step a round held and the step above it that failed; the resolution gives that gap as a share")
    print("of the step held. The table gives the round whose rate held is the median, and the range of the rates the")
    print("rounds held. The load runs on two cores of its own, which the server never runs on. A step that fails while")
    print("they were 90% busy or more ends the round on the load's cores, and its rate held is then a floor, with no")
    print('resolution. "load busy" is their share at the step held: all their work, the kernel\'s for the traffic the')
    print(
        f'load sends included. "p99 ≤ {low_limit_ms} ms" gives the most spans a second a step of the first round held with'
    )
    print(f"p99 at most {low_limit_ms} ms.")
    print()
    print(
        f"| server | spans/s held | range | resolution | calls/s | p50 ms | p99 ms | core busy | load busy | CPU µs a span | peak MiB | p99 ≤ {low_limit_ms} ms | the next step |"
    )
    print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|")


def write_held(report, servers, steps, memory):
    """A row of the table for each server, and each server's summary by `climb.summary`, by
    server, for the servers whose rounds held a step."""
    ended_by = report.ended_by
    held = {}
    for server in servers:
        result, verdict = climb.summary(steps.get(server, []))
        if result is None:
            print(f"| {names[server]} | none | | | | | | | | | | | {ended_by.get(verdict, verdict)} |")
            continue
        held[server] = result
        step = result["best"]
        gap = climb.resolution(step, result["above"])
        # A run with no core pinned measures no load's share.
        load = "" if step["load"] < 0 else f"{step['load'] * percent:.0f}%"
        quick = climb.low_latency(steps[server], low_limit_ms)
        quick_text = "" if quick is None else f"{quick['spans']:,.0f}"
        print(
            f"| {names[server]} | {step['spans']:,.0f} | {result['low']:,.0f}–{result['high']:,.0f} | "
            f"{'' if gap is None else f'+{gap * percent:.1f}%'} | "
            f"{step['calls']:,.0f} | {step['p50']:.2f} | {step['p99']:.2f} | "
            f"{step['busy'] * percent:.0f}% | {load} | "
            f"{step['cpu']:.2f} | {memory.get(server, 0):.0f} | {quick_text} | "
            f"{ended_by.get(verdict, verdict)} |"
        )
    print()
    return held


def validation_line(report, steps, held, server, twin):
    """What validation costs a receiver: the share of its twin's rate it holds, or that the rounds
    cannot tell the two apart, and the CPU a span of each at the highest rate both first rounds
    held."""
    share = held[server]["best"]["spans"] / held[twin]["best"]["spans"] * percent
    ratios = climb.round_ratios(held[server], held[twin])
    spread = f", {min(ratios) * percent:.0f}% to {max(ratios) * percent:.0f}% round by round" if ratios else ""
    if not climb.overlap(held[server], held[twin]):
        bound = climb.bound(held[server]["above"], held[twin]["above"])
        line = f"{names[server]} holds {bound}{share:.0f}% of {twin}'s spans a second{spread}"
    else:
        line = f"{names[server]} and {twin} hold rates the rounds cannot tell apart ({share:.0f}%{spread})"
    mine_steps, theirs_steps = climb.first_round(steps[server]), climb.first_round(steps[twin])
    rate = climb.common_rate(mine_steps, theirs_steps)
    if rate is None:
        return line + "."
    mine, theirs = climb.at(mine_steps, rate), climb.at(theirs_steps, rate)
    return (
        line
        + f". At {rate * report.spans_per_rate:,.0f} spans a second, which both held, it spends {mine['cpu']:.2f} µs "
        f"of CPU a span to its {theirs['cpu']:.2f}, {(mine['cpu'] / theirs['cpu'] - 1) * percent:+.0f}%."
    )


def zig_line(held, server):
    """How connect-zig's rate compares with a server's: the median rounds' ratio, and each round's."""
    zig = held["connect-zig"]
    ratios = climb.round_ratios(zig, held[server])
    spread = f", {min(ratios):.2f} to {max(ratios):.2f} times round by round" if ratios else ""
    bound = climb.bound(zig["above"], held[server]["above"])
    return (
        f"- connect-zig holds {bound}{zig['best']['spans'] / held[server]['best']['spans']:.2f} times "
        f"{names[server]}'s spans a second on one core{spread}."
    )


def write_closed(servers, steps, held):
    """A line for each server that closed connections under load: the load opened them again
    before its next step."""
    closed = [(server, sum(step["reopened"] for step in steps.get(server, []))) for server in servers]
    for server, reopened in closed:
        if reopened:
            print(f"- {names[server]} closed connections: the load opened {reopened:,} again over its rounds.")
    if any(reopened for _, reopened in closed) and "connect-zig" not in held:
        print()


def write_comparisons(report, servers, steps, held):
    """The connections each server closed, and with connect-zig's rounds, how the others compare."""
    write_closed(servers, steps, held)
    if "connect-zig" not in held:
        return
    for server in servers[1:]:
        if server in held and not server.endswith("-validate"):
            print(zig_line(held, server))
    for server, twin in validating:
        if server in held and twin in held:
            print(f"- {validation_line(report, steps, held, server, twin)}")
    carried = ", ".join(
        f"{names[server]} {held[server]['best']['spans'] * gateway_cores / fleet_servers:,.0f}"
        for server in servers
        if server in held
    )
    print(
        f"- At {gateway_cores} cores, the spans a second each server carries for each of the {fleet_servers:,} servers: {carried}."
    )
    print()


def write_confirms(report, servers):
    """The long step of each server after its rounds: the step at the median rate held, the one
    with the most spans a second, and not the step at half of it before."""
    confirms = climb.read(report.results, report.transport, report.ticks, report.seconds, "confirm")[1]
    if not confirms:
        return
    print(
        f"Each server then ran one step of {report.confirm_seconds:.0f} s at the median rate its rounds held, on a new process, after a step"
    )
    print("at half of it.")
    print()
    print("| server | spans/s sent | spans/s taken | p99 ms | core busy | the step |")
    print("|---|--:|--:|--:|--:|---|")
    for server in servers:
        if server not in confirms:
            continue
        step = max(confirms[server], key=lambda item: item["rate"])
        verdict = "held" if step["verdict"] == "pass" else report.ended_by.get(step["verdict"], step["verdict"])
        print(
            f"| {names[server]} | {step['rate'] * report.spans_per_rate:,.0f} | {step['spans']:,.0f} | {step['p99']:.2f} | "
            f"{step['busy'] * percent:.0f}% | {verdict} |"
        )
    print()


def write_first_round(report, servers, steps):
    """The first round's climb, one row a step, with each server's p99 and core busy."""
    print(
        "The first round's climb, one row for each step: p99 in milliseconds and the share of its core each server kept"
    )
    print("busy.")
    print()
    print(
        "| exports a connection a second | spans/s sent | "
        + " | ".join(f"{names[server]} p99 | {names[server]} core" for server in servers)
        + " |"
    )
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
        print(f"| {rate:g} | {rate * report.spans_per_rate:,.0f} | " + " | ".join(cells) + " |")
    print()


def write_footer(report, servers, machine_text):
    print(f"Machine: {machine_text}.")
    print(f"Load: {report.load_text}, {report.placement}.")
    chosen = climb.suites(report.results, report.transport)
    if chosen:
        print(
            "TLS: the load offers AES-128-GCM alone, in TLS 1.3 and in TLS 1.2, and each server's connections ran "
            + ", ".join(f"{names.get(server, server)} {chosen[server]}" for server in servers if server in chosen)
            + "."
        )
    runs = setups(report)
    print(
        f"Servers: connect-zig {report.commit} in ReleaseSafe, `tools/otlp_sink`; "
        + "; ".join(runs[server] for server in servers if server in runs)
        + "."
    )


def write(report, machine_text):
    """The whole report, on standard output."""
    servers, steps, memory = climb.read(report.results, report.transport, report.ticks, report.seconds)
    write_intro(report)
    held = write_held(report, servers, steps, memory)
    write_comparisons(report, servers, steps, held)
    write_confirms(report, servers)
    write_first_round(report, servers, steps)
    write_footer(report, servers, machine_text)


def main():
    write(parse(sys.argv[1:]), machine())


if __name__ == "__main__":
    main()
