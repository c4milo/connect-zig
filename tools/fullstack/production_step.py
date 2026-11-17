#!/usr/bin/env python3
"""Reads one step of tools/fullstack/production.sh from oha's CSV files (decision 44).

    tools/fullstack/production_step.py <work> <warm> <seconds> <limit_ms> <rate> <spans:connections>...

<work>/step-<spans>.csv holds a line for each call of the class whose exports hold <spans> spans:
its start in seconds after the load began, its duration with oha's latency correction, and its
HTTP status. The step's calls that start after <warm> seconds are its measure, over the rest of
its <seconds>. The script prints, on one line: the spans of every call answered 200, which the
server's count must hold; the measured calls a second and spans a second; p50 and p99 in
milliseconds over every class; the calls answered with another status; and the verdict. The
verdict is "pass", or names what failed: "refused", "p99" past <limit_ms>, or "rate" when the
measured spans fall short of 95% of the step's.
"""
import csv
import os
import sys

work, warm, seconds, limit_ms, rate = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
classes = [tuple(int(part) for part in item.split(":")) for item in sys.argv[6:]]
reach = 0.95
milliseconds = 1000

taken, measured_calls, measured_spans, refused, latencies, target = 0, 0, 0, 0, [], 0
for spans, connections in classes:
    target += rate * connections * spans
    with open(os.path.join(work, f"step-{spans}.csv")) as file:
        for row in csv.DictReader(file):
            if row["status"] != "200":
                refused += 1
                continue
            taken += spans
            if float(row["request-start"]) < warm:
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
print(f"{taken} {measured_calls / window:.0f} {spans_per_second:.0f} {p50:.2f} {p99:.2f} {refused} {verdict}")
