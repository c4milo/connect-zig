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

from machine import machine

work, ticks, h2load, otelcol, vector, connect_go, connect_rust, commit, placement, rounds, connections, streams, suite, go_memory = sys.argv[1:15]
ticks = int(ticks)
# The limit as the report names it: 75 MiB.
go_memory_label = go_memory.replace("MiB", " MiB")
servers = [("connect-zig", "connect-zig"), ("connect-zig-generic", "connect-zig, generic CPU"),
           ("connect-zig-validate", "connect-zig + protovalidate"),
           ("collector", "Collector"), ("vector", "Vector"), ("connect-go", "connect-go"),
           ("connect-go-memory", f"connect-go, {go_memory_label}"),
           ("connect-go-validate", "connect-go + protovalidate-go"),
           ("connect-rust", "connect-rust"), ("connect-rust-validate", "connect-rust + protovalidate-buffa")]
# Each receiver that validates, and its twin that does not.
validating = [("connect-zig-validate", "connect-zig"), ("connect-go-validate", "connect-go"),
              ("connect-rust-validate", "connect-rust")]
percent = 100
microseconds = 1_000_000
kib = 1024
# The octets of gRPC's prefix before each message (gRPC over HTTP/2, "Requests").
prefix_len = 5

rows = {}
for line in open(os.path.join(work, "peak-results")):
    spans, server, rate, p50, p99, cpu_ticks, calls, peak = line.split()
    rows.setdefault((int(spans), server), []).append({
        "rate": float(rate),
        "p50": int(p50) / 1000,
        "p99": int(p99) / 1000,
        "cpu": int(cpu_ticks) * microseconds / ticks / int(calls),
        "peak": int(peak) / kib,
    })


def median(spans, server, key):
    values = [row[key] for row in rows.get((spans, server), [])]
    return statistics.median(values) if values else None


spans_list = sorted({spans for spans, _ in rows})
print("## Full stack, peak: OTLP's trace export over TLS and h2")
print()
print("Each server answers OTLP's `TraceService/Export` over gRPC on a socket, and h2load sends each")
print("the same export. Each cell is the median of the rounds, and each round checked every span.")
print()
print("| export | server | calls/s | p50 ms | p99 ms | CPU µs a call | peak MiB |")
print("|---|---|--:|--:|--:|--:|--:|")
for spans in spans_list:
    octets = os.path.getsize(os.path.join(work, f"export-{spans}.grpc")) - prefix_len
    for server, name in servers:
        if median(spans, server, "rate") is None:
            print(f"| {spans} spans, {octets:,} B | {name} | absent | | | | |")
            continue
        print(f"| {spans} spans, {octets:,} B | {name} | {median(spans, server, 'rate'):,.0f} | "
              f"{median(spans, server, 'p50'):.2f} | {median(spans, server, 'p99'):.2f} | "
              f"{median(spans, server, 'cpu'):.1f} | {median(spans, server, 'peak'):.1f} |")
print()
for spans in spans_list:
    zig_rate, zig_cpu = median(spans, "connect-zig", "rate"), median(spans, "connect-zig", "cpu")
    for server, name in servers[1:]:
        rate, cpu = median(spans, server, "rate"), median(spans, server, "cpu")
        if server.endswith(("-validate", "-generic", "-memory")) or None in (zig_rate, zig_cpu, rate, cpu):
            continue
        print(f"- {spans} spans: connect-zig answers {zig_rate / rate:.2f} times {name}'s calls a second, and "
              f"spends {zig_cpu / cpu:.2f} times its CPU time a call.")
    names = dict(servers)
    rate, cpu = median(spans, "connect-zig-generic", "rate"), median(spans, "connect-zig-generic", "cpu")
    if None not in (rate, cpu, zig_rate, zig_cpu):
        print(f"- {spans} spans: connect-zig built for the generic CPU answers {rate / zig_rate * percent:.1f}% of the "
              f"calls a second of its build for this CPU, and spends {(cpu / zig_cpu - 1) * percent:+.0f}% CPU time a call.")
    rate, cpu = median(spans, "connect-go-memory", "rate"), median(spans, "connect-go-memory", "cpu")
    go_rate, go_cpu = median(spans, "connect-go", "rate"), median(spans, "connect-go", "cpu")
    if None not in (rate, cpu, go_rate, go_cpu, zig_rate):
        print(f"- {spans} spans: connect-go with {go_memory_label} and its collector off below it answers {rate / go_rate * percent:.1f}% "
              f"of connect-go's calls a second, and spends {(cpu / go_cpu - 1) * percent:+.0f}% CPU time a call; connect-zig "
              f"answers {zig_rate / rate:.2f} times its calls a second.")
    for server, twin in validating:
        rate, cpu = median(spans, server, "rate"), median(spans, server, "cpu")
        twin_rate, twin_cpu = median(spans, twin, "rate"), median(spans, twin, "cpu")
        if None in (rate, cpu, twin_rate, twin_cpu):
            continue
        print(f"- {spans} spans: {names[server]} answers {rate / twin_rate * percent:.1f}% of {twin}'s calls a "
              f"second, and spends {cpu - twin_cpu:.1f} µs more CPU time a call.")
print()
print(f"Machine: {machine()}.")
print(f"Load: {h2load}, {connections} connections of {streams} streams each, {suite}; {placement}.")
print(f"Servers: connect-zig {commit} in ReleaseSafe for this CPU, `tools/otlp_sink`, and the same for the generic CPU; "
      f"{otelcol}, GOMAXPROCS=1, its OTLP")
print(f"receiver into its nop exporter; {vector}, one thread, its opentelemetry source into its blackhole sink;")
print(f"{connect_go}, GOMAXPROCS=1, and {connect_rust}, one tokio worker, each a receiver that counts spans")
print(f"(`tools/fullstack/connect-go`, `tools/fullstack/connect-rust`). \"connect-go, {go_memory_label}\" runs with GOGC=off and")
print(f"GOMEMLIMIT={go_memory}, about what connect-zig's sink holds, so its collector runs only as its heap nears that.")
print("connect-zig + protovalidate is `otlp-sink-validate`,")
print("and connect-go + protovalidate-go and connect-rust + protovalidate-buffa the same receivers with `validate`: each")
print("checks every export against the rules of `tools/fullstack/validate` before it counts its spans.")
print(f"Rounds: {rounds}.")
