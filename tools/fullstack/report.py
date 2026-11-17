#!/usr/bin/env python3
"""Writes the report of tools/fullstack_check.sh (design §8 step 28) on standard output.

    tools/fullstack/report.py <work> <ticks> <h2load> <otelcol> <commit> <placement> <rounds>
                              <connections> <streams> <suite>

<work>/results holds a line for each round of a server and an export: the spans, the server, the
calls a second, the latency at p50 and p99 in microseconds, the server's CPU ticks over the
measured calls, the measured calls, and the server's peak memory in KiB. <ticks> is the ticks of a
second of CPU time. Each cell of the table is the median of the rounds, taken for each measure
alone.
"""
import os
import statistics
import subprocess
import sys

work, ticks, h2load, otelcol, commit, placement, rounds, connections, streams, suite = sys.argv[1:11]
ticks = int(ticks)
servers = [("connect-zig", "connect-zig"), ("collector", "Collector")]
microseconds = 1_000_000
kib = 1024
# The octets of gRPC's prefix before each message (gRPC over HTTP/2, "Requests").
prefix_len = 5

rows = {}
for line in open(os.path.join(work, "results")):
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


def machine():
    """The CPU's model and the cores, as lscpu names them."""
    found = subprocess.run(["lscpu"], capture_output=True, text=True).stdout
    model = next((line.split(":", 1)[1].strip() for line in found.splitlines() if line.startswith("Model name:")), "unknown")
    return f"{model}, {os.cpu_count()} cores, Linux {os.uname().release}"


spans_list = sorted({spans for spans, _ in rows})
print("## Full stack: OTLP's trace export over TLS and h2")
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
    zig_rate, collector_rate = median(spans, "connect-zig", "rate"), median(spans, "collector", "rate")
    zig_cpu, collector_cpu = median(spans, "connect-zig", "cpu"), median(spans, "collector", "cpu")
    if None in (zig_rate, collector_rate, zig_cpu, collector_cpu):
        continue
    print(f"- {spans} spans: connect-zig answers {zig_rate / collector_rate:.2f} times the Collector's calls a "
          f"second, and spends {zig_cpu / collector_cpu:.2f} times its CPU time a call.")
print()
print(f"Machine: {machine()}.")
print(f"Load: {h2load}, {connections} connections of {streams} streams each, {suite}; {placement}.")
print(f"Servers: connect-zig {commit} in ReleaseSafe, `tools/otlp_sink`; {otelcol}, GOMAXPROCS=1, the OTLP")
print(f"receiver into the nop exporter, no processor. Rounds: {rounds}.")
