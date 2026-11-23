#!/usr/bin/env python3
"""Reads one step of tools/fullstack/production.sh from oha's CSV files (decision 44).

    tools/fullstack/production_step.py <work> <warm> <seconds> <limit_ms> <rate> <load_before>
                                       <load_after> <spans:connections>...

<work>/step-<spans>.csv holds a line for each call of the class whose exports hold <spans> spans:
its start in seconds after the load began, its duration with oha's latency correction, and its
HTTP status. The step's calls that start after <warm> seconds are its measure, over the rest of
its <seconds>. The script prints, on one line: the spans of every call answered 200, which the
server's count must hold; the measured calls a second and spans a second; p50 and p99 in
milliseconds over every class; the measured calls answered with another status; the verdict;
the calls answered with another status in the first <warm> seconds; and the share of the load's
cores that was busy, from <load_before> and <load_after>, each `<busy>:<total>` ticks of
/proc/stat, or `-` when no core is pinned. oha runs on those cores alone, and the server on
another; the share counts all their work, the kernel's for the traffic oha sends included. The verdict is "pass", or names what failed: "refused",
"p99" past <limit_ms>, or "rate" when the measured spans fall short of 95% of the step's. A step
that fails while its load's cores were 90% busy or more is "load" instead: oha corrects its
latency for each call it sends late, so a load that falls behind shows as the server's p99.

A step opens its 516 connections again, and a server takes their TLS handshakes and the calls
queued behind them at once. The measure leaves those first seconds out, for latency and for
refusals alike: a server that queues them shows it as latency there, and one that refuses
calls past a fixed count, as connect-zig's sink does past its 64, shows it as refusals there
(decision 44 as amended). The report counts those refusals apart.
"""
import csv
import os
import sys

work, warm, seconds, limit_ms, rate = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
load_before, load_after = sys.argv[6], sys.argv[7]
classes = [tuple(int(part) for part in item.split(":")) for item in sys.argv[8:]]
reach = 0.95
# The busy share of the load's cores past which a failed step names the load: oha's threads then
# wait for a core, and send calls late.
load_full = 0.9
milliseconds = 1000


def load_busy():
    """The share of the load's cores that was busy over the step, or -1 with no core pinned."""
    if "-" in (load_before, load_after):
        return -1
    busy_before, total_before = (int(part) for part in load_before.split(":"))
    busy_after, total_after = (int(part) for part in load_after.split(":"))
    return (busy_after - busy_before) / max(total_after - total_before, 1)

taken, measured_calls, measured_spans, refused, warm_refused, latencies, target = 0, 0, 0, 0, 0, [], 0
for spans, connections in classes:
    target += rate * connections * spans
    with open(os.path.join(work, f"step-{spans}.csv")) as file:
        for row in csv.DictReader(file):
            early = float(row["request-start"]) < warm
            if row["status"] != "200":
                if early:
                    warm_refused += 1
                else:
                    refused += 1
                continue
            taken += spans
            if early:
                continue
            measured_calls += 1
            measured_spans += spans
            latencies.append(float(row["request-duration"]) * milliseconds)


def rank(sorted_values, share):
    """The nearest rank: the smallest value at or above `share` of the values."""
    if not sorted_values:
        return float("inf")
    place = max(1, -(-len(sorted_values) * share // 1))
    return sorted_values[int(place) - 1]


latencies.sort()
window = seconds - warm
p50, p99 = rank(latencies, 0.5), rank(latencies, 0.99)
spans_per_second = measured_spans / window
verdict = "pass"
if refused:
    verdict = "refused"
elif p99 > limit_ms:
    verdict = "p99"
elif spans_per_second < reach * target:
    verdict = "rate"
busy = load_busy()
if verdict in ("p99", "rate") and busy >= load_full:
    verdict = "load"
print(f"{taken} {measured_calls / window:.0f} {spans_per_second:.0f} {p50:.2f} {p99:.2f} {refused} {verdict} {warm_refused} {busy:.3f}")
