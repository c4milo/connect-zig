#!/usr/bin/env python3
"""Writes the peak report of tools/fullstack/peak.sh (design §8 step 28) on standard output.

    tools/fullstack/peak_report.py <work> <ticks> <h2load> <otelcol> <vector> <connect-go>
                                   <connect-rust> <commit> <placement> <rounds> <connections>
                                   <streams> <suite> <go-memory>

<work>/peak-results holds a line for each round of a server and an export: the spans, the server, the
calls a second, the latency at p50 and p99 in microseconds, the server's CPU ticks over the
measured calls, the measured calls, and the server's peak memory in KiB. <ticks> is the ticks of a
second of CPU time. Each cell of the table is the median of the rounds, taken for each measure
alone. <go-memory> is the GOMEMLIMIT of connect-go-memory, such as 75MiB.
"""

import os
import statistics
import sys
import types

from machine import machine

# Each receiver that validates, and its twin that does not.
validating = [
    ("connect-zig-validate", "connect-zig"),
    ("connect-go-validate", "connect-go"),
    ("connect-rust-validate", "connect-rust"),
]
percent = 100
microseconds = 1_000_000
kib = 1024
# The octets of gRPC's prefix before each message (gRPC over HTTP/2, "Requests").
prefix_len = 5
argument_names = [
    "work",
    "ticks",
    "h2load",
    "otelcol",
    "vector",
    "connect_go",
    "connect_rust",
    "commit",
    "placement",
    "rounds",
    "connections",
    "streams",
    "suite",
    "go_memory",
]


def parse(arguments):
    """The command line's values by name, with the ticks as a number."""
    report = types.SimpleNamespace(**dict(zip(argument_names, arguments[: len(argument_names)], strict=True)))
    report.ticks = int(report.ticks)
    # The limit as the report names it: 75 MiB.
    report.go_memory_label = report.go_memory.replace("MiB", " MiB")
    return report


def server_names(go_memory_label):
    """Each server, in the table's order, and its name in the report."""
    return [
        ("connect-zig", "connect-zig"),
        ("connect-zig-generic", "connect-zig, generic CPU"),
        ("connect-zig-validate", "connect-zig + protovalidate"),
        ("collector", "Collector"),
        ("vector", "Vector"),
        ("connect-go", "connect-go"),
        ("connect-go-memory", f"connect-go, {go_memory_label}"),
        ("connect-go-validate", "connect-go + protovalidate-go"),
        ("connect-rust", "connect-rust"),
        ("connect-rust-validate", "connect-rust + protovalidate-buffa"),
    ]


def read(work, ticks):
    """Each round's measures, by the export's spans and the server."""
    rows = {}
    with open(os.path.join(work, "peak-results")) as lines:
        for line in lines:
            spans, server, rate, p50, p99, cpu_ticks, calls, peak = line.split()
            rows.setdefault((int(spans), server), []).append(
                {
                    "rate": float(rate),
                    "p50": int(p50) / 1000,
                    "p99": int(p99) / 1000,
                    "cpu": int(cpu_ticks) * microseconds / ticks / int(calls),
                    "peak": int(peak) / kib,
                }
            )
    return rows


def median(rows, spans, server, key):
    """The median of a measure over the rounds, or None when the server has no round."""
    values = [row[key] for row in rows.get((spans, server), [])]
    return statistics.median(values) if values else None


def write_table(report, rows, servers):
    spans_list = sorted({spans for spans, _ in rows})
    print("## Full stack, peak: OTLP's trace export over TLS and h2")
    print()
    print("Each server answers OTLP's `TraceService/Export` over gRPC on a socket, and h2load sends each")
    print("the same export. Each cell is the median of the rounds, and each round checked every span.")
    print()
    print("| export | server | calls/s | p50 ms | p99 ms | CPU µs a call | peak MiB |")
    print("|---|---|--:|--:|--:|--:|--:|")
    for spans in spans_list:
        octets = os.path.getsize(os.path.join(report.work, f"export-{spans}.grpc")) - prefix_len
        for server, name in servers:
            if median(rows, spans, server, "rate") is None:
                print(f"| {spans} spans, {octets:,} B | {name} | absent | | | | |")
                continue
            print(
                f"| {spans} spans, {octets:,} B | {name} | {median(rows, spans, server, 'rate'):,.0f} | "
                f"{median(rows, spans, server, 'p50'):.2f} | {median(rows, spans, server, 'p99'):.2f} | "
                f"{median(rows, spans, server, 'cpu'):.1f} | {median(rows, spans, server, 'peak'):.1f} |"
            )
    print()


def write_comparisons(report, rows, servers, spans):
    """The lines that compare connect-zig with each other server for one export."""
    zig_rate, zig_cpu = median(rows, spans, "connect-zig", "rate"), median(rows, spans, "connect-zig", "cpu")
    for server, name in servers[1:]:
        rate, cpu = median(rows, spans, server, "rate"), median(rows, spans, server, "cpu")
        if server.endswith(("-validate", "-generic", "-memory")) or None in (zig_rate, zig_cpu, rate, cpu):
            continue
        print(
            f"- {spans} spans: connect-zig answers {zig_rate / rate:.2f} times {name}'s calls a second, and "
            f"spends {zig_cpu / cpu:.2f} times its CPU time a call."
        )
    names = dict(servers)
    rate, cpu = median(rows, spans, "connect-zig-generic", "rate"), median(rows, spans, "connect-zig-generic", "cpu")
    if None not in (rate, cpu, zig_rate, zig_cpu):
        print(
            f"- {spans} spans: connect-zig built for the generic CPU answers {rate / zig_rate * percent:.1f}% of the "
            f"calls a second of its build for this CPU, and spends {(cpu / zig_cpu - 1) * percent:+.0f}% CPU time a call."
        )
    rate, cpu = median(rows, spans, "connect-go-memory", "rate"), median(rows, spans, "connect-go-memory", "cpu")
    go_rate, go_cpu = median(rows, spans, "connect-go", "rate"), median(rows, spans, "connect-go", "cpu")
    if None not in (rate, cpu, go_rate, go_cpu, zig_rate):
        print(
            f"- {spans} spans: connect-go with {report.go_memory_label} and its collector off below it answers {rate / go_rate * percent:.1f}% "
            f"of connect-go's calls a second, and spends {(cpu / go_cpu - 1) * percent:+.0f}% CPU time a call; connect-zig "
            f"answers {zig_rate / rate:.2f} times its calls a second."
        )
    for server, twin in validating:
        rate, cpu = median(rows, spans, server, "rate"), median(rows, spans, server, "cpu")
        twin_rate, twin_cpu = median(rows, spans, twin, "rate"), median(rows, spans, twin, "cpu")
        if None in (rate, cpu, twin_rate, twin_cpu):
            continue
        print(
            f"- {spans} spans: {names[server]} answers {rate / twin_rate * percent:.1f}% of {twin}'s calls a "
            f"second, and spends {cpu - twin_cpu:.1f} µs more CPU time a call."
        )


def write_footer(report, machine_text):
    print(f"Machine: {machine_text}.")
    print(
        f"Load: {report.h2load}, {report.connections} connections of {report.streams} streams each, {report.suite}; "
        f"{report.placement}."
    )
    print(
        f"Servers: connect-zig {report.commit} in ReleaseSafe for this CPU, `tools/otlp_sink`, and the same for the generic CPU; "
        f"{report.otelcol}, GOMAXPROCS=1, its OTLP"
    )
    print(
        f"receiver into its nop exporter; {report.vector}, one thread, its opentelemetry source into its blackhole sink;"
    )
    print(
        f"{report.connect_go}, GOMAXPROCS=1, and {report.connect_rust}, one tokio worker, each a receiver that counts spans"
    )
    print(
        f'(`tools/fullstack/connect-go`, `tools/fullstack/connect-rust`). "connect-go, {report.go_memory_label}" runs with GOGC=off and'
    )
    print(
        f"GOMEMLIMIT={report.go_memory}, about what connect-zig's sink holds, so its collector runs only as its heap nears that."
    )
    print("connect-zig + protovalidate is `otlp-sink-validate`,")
    print(
        "and connect-go + protovalidate-go and connect-rust + protovalidate-buffa the same receivers with `validate`: each"
    )
    print("checks every export against the rules of `tools/fullstack/validate` before it counts its spans.")
    print(f"Rounds: {report.rounds}.")


def write(report, machine_text):
    """The whole report, on standard output."""
    rows = read(report.work, report.ticks)
    servers = server_names(report.go_memory_label)
    write_table(report, rows, servers)
    for spans in sorted({spans for spans, _ in rows}):
        write_comparisons(report, rows, servers, spans)
    print()
    write_footer(report, machine_text)


def main():
    write(parse(sys.argv[1:]), machine())


if __name__ == "__main__":
    main()
