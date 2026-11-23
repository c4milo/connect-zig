#!/usr/bin/env python3
"""Reads one step of tools/fullstack/production.sh from the load's CSV files (decision 44).

    tools/fullstack/production_step.py <work> <seconds> <limit_ms> <rate> <load_before>
                                       <load_after> <spans:connections>...

<work>/step-<spans>.csv holds a line for each call of the class whose exports hold <spans> spans:
the instant its connection's schedule set for it, in seconds after the step began, its duration
from that instant, and its status, `200` for an answer of HTTP 200 and grpc-status 0. The script
prints, on one line: the spans of every call answered 200, which the server's count must hold;
the calls a second and spans a second over the step's <seconds>; p50 and p99 in milliseconds over
every class; the calls answered with another status; the verdict; and the share of the load's
cores that was busy, from <load_before> and <load_after>, each `<busy>:<total>` ticks of
/proc/stat, or `-` when no core is pinned. The load runs on those cores alone, and the server on
another; the share counts all their work, the kernel's for the traffic the load sends included.

The verdict is "pass", or names what failed: "refused", "p99" past <limit_ms>, or "rate" when the
spans fall short of 95% of the step's. A step that fails while its load's cores were 90% busy or
more is "load" instead: the load counts a call's latency from the instant its schedule set, so a
load that falls behind shows as the server's p99.

The load keeps its connections open across the climb, as the agents keep theirs, so a step holds
no TLS handshake and every call counts: a server that refuses one, as connect-zig's sink does past
the calls its routes hold, fails the step (decision 44 as amended).
"""

import csv
import os
import sys

reach = 0.95
# The busy share of the load's cores past which a failed step names the load: its threads then
# wait for a core, and send calls late.
load_full = 0.9
milliseconds = 1000
p50_share, p99_share = 0.5, 0.99


def load_busy(load_before, load_after):
    """The share of the load's cores that was busy over the step, or -1 with no core pinned."""
    if "-" in (load_before, load_after):
        return -1
    busy_before, total_before = (int(part) for part in load_before.split(":"))
    busy_after, total_after = (int(part) for part in load_after.split(":"))
    return (busy_after - busy_before) / max(total_after - total_before, 1)


def rank(sorted_values, share):
    """The nearest rank: the smallest value at or above `share` of the values."""
    if not sorted_values:
        return float("inf")
    place = max(1, -(-len(sorted_values) * share // 1))
    return sorted_values[int(place) - 1]


def read(work, classes, rate):
    """The spans of the calls answered 200, those calls, the calls refused, the latency of each
    call answered in milliseconds, sorted, and the spans the step's rate sends."""
    taken, calls, refused, latencies, target = 0, 0, 0, [], 0
    for spans, connections in classes:
        target += rate * connections * spans
        with open(os.path.join(work, f"step-{spans}.csv")) as file:
            for row in csv.DictReader(file):
                if row["status"] != "200":
                    refused += 1
                    continue
                taken += spans
                calls += 1
                latencies.append(float(row["request-duration"]) * milliseconds)
    latencies.sort()
    return taken, calls, refused, latencies, target


def judge(refused, p99, limit_ms, spans_per_second, target, busy):
    """The step's verdict: "pass", or what failed, and "load" for a failed step whose load's cores
    were full."""
    verdict = "pass"
    if refused:
        verdict = "refused"
    elif p99 > limit_ms:
        verdict = "p99"
    elif spans_per_second < reach * target:
        verdict = "rate"
    if verdict in ("p99", "rate") and busy >= load_full:
        verdict = "load"
    return verdict


def step_line(work, seconds, limit_ms, rate, load_before, load_after, classes):
    """The step's line, as the script prints it."""
    taken, calls, refused, latencies, target = read(work, classes, rate)
    p50, p99 = rank(latencies, p50_share), rank(latencies, p99_share)
    spans_per_second = taken / seconds
    busy = load_busy(load_before, load_after)
    verdict = judge(refused, p99, limit_ms, spans_per_second, target, busy)
    return f"{taken} {calls / seconds:.0f} {spans_per_second:.0f} {p50:.2f} {p99:.2f} {refused} {verdict} {busy:.3f}"


def main():
    work, seconds, limit_ms, rate = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
    classes = [tuple(int(part) for part in item.split(":")) for item in sys.argv[7:]]
    print(step_line(work, seconds, limit_ms, rate, sys.argv[5], sys.argv[6], classes))


if __name__ == "__main__":
    main()
