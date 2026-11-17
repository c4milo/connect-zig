#!/usr/bin/env python3
"""Writes the peak report of tools/fullstack/peak.sh (design §8 step 28) on standard output.

    tools/fullstack/peak_report.py <work> <ticks> <h2load> <otelcol> <vector> <commit> <placement>
                                   <rounds> <connections> <streams> <suite>

<work>/peak-results holds a line for each round of a server and an export: the spans, the server, the
calls a second, the latency at p50 and p99 in microseconds, the server's CPU ticks over the
measured calls, the measured calls, and the server's peak memory in KiB. <ticks> is the ticks of a
second of CPU time. Each cell of the table is the median of the rounds, taken for each measure
alone.
"""
import os
import statistics
import sys

from machine import machine

work, ticks, h2load, otelcol, vector, commit, placement, rounds, connections, streams, suite = sys.argv[1:12]
ticks = int(ticks)
servers = [("connect-zig", "connect-zig"), ("collector", "Collector"), ("vector", "Vector")]
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
        if None in (zig_rate, zig_cpu, rate, cpu):
            continue
        print(f"- {spans} spans: connect-zig answers {zig_rate / rate:.2f} times {name}'s calls a second, and "
              f"spends {zig_cpu / cpu:.2f} times its CPU time a call.")
print()
print(f"Machine: {machine()}.")
print(f"Load: {h2load}, {connections} connections of {streams} streams each, {suite}; {placement}.")
print(f"Servers: connect-zig {commit} in ReleaseSafe, `tools/otlp_sink`; {otelcol}, GOMAXPROCS=1, its OTLP")
print(f"receiver into its nop exporter; {vector}, one thread, its opentelemetry source into its blackhole sink.")
print(f"Rounds: {rounds}.")
