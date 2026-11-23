"""The climbs of tools/fullstack/production.sh, as tools/fullstack's reports read them.

A climb's results hold a line for each step of each server: "step", the transport, the server,
the exports a connection a second, the spans of the calls answered 200, the calls a second and
spans a second, p50 and p99 in milliseconds, the calls refused, the verdict, the share of the
load's cores that was busy, -1 with no core pinned, the server's CPU ticks over the step, the
step's wall time in milliseconds, the connections the load opened again before the step because
the server had closed them, and the round. A line "memory" gives the transport, the server and
its peak memory in KiB, and a line "suite" the transport, the server and the TLS 1.3 suite its
connections ran.

Each server runs in rounds. The first climbs from the lowest rate, and each later one searches
near the rate an earlier one held, so only the first round's steps fall on the same rates for
every server.
"""

import statistics
import sys

microseconds = 1_000_000
milliseconds = 1000
kib = 1024


def read(path, transport, ticks, seconds, kind="step"):
    """The servers in the order the file names them, each server's steps, and each server's peak
    memory in MiB, for the lines of `transport`. `kind` picks the lines of the steps: "step" for
    the rounds, or "confirm" for the long step at the rate a server held."""
    servers, steps, memory = [], {}, {}
    with open(path) as lines:
        for line in lines:
            fields = line.split()
            if len(fields) < 3 or fields[1] != transport:
                continue
            server = fields[2]
            if server not in servers:
                servers.append(server)
            if fields[0] == "memory":
                memory[server] = max(memory.get(server, 0), int(fields[3]) / kib)
                continue
            if fields[0] != kind:
                continue
            rate, taken, calls, spans, p50, p99, refused, verdict, load, cpu, wall_ms, reopened, round_number = fields[
                3:16
            ]
            steps.setdefault(server, []).append(
                {
                    "rate": float(rate),
                    "taken": int(taken),
                    "calls": float(calls),
                    "spans": float(spans),
                    "p50": float(p50),
                    "p99": float(p99),
                    "refused": int(refused),
                    "verdict": verdict,
                    "load": float(load),
                    "reopened": int(reopened),
                    "round": int(round_number),
                    # The share of a core over the step's measured wall time, which passes its nominal
                    # seconds by the load's start and the calls still in flight at its end.
                    "busy": int(cpu) / ticks / max(int(wall_ms) / milliseconds, seconds),
                    "cpu": int(cpu) * microseconds / ticks / max(int(taken), 1),
                }
            )
    return servers, steps, memory


def suites(path, transport):
    """The TLS 1.3 suite each server's connections ran, by server, from the lines of `transport`."""
    found = {}
    with open(path) as lines:
        for line in lines:
            fields = line.split()
            if len(fields) == 4 and fields[0] == "suite" and fields[1] == transport:
                found[fields[2]] = fields[3]
    return found


def held(steps):
    """The highest step the server passed, the lowest step above it that failed, and that step's
    verdict. After its first failure, the climb tries rates between, so its steps are not in
    order. The rate the core holds lies between the two steps. A step that failed on its load
    bounds nothing, so the rate held is then a floor, as when no step above failed."""
    passed = [step for step in steps if step["verdict"] == "pass"]
    best = max(passed, key=lambda step: step["rate"]) if passed else None
    floor = best["rate"] if best else 0
    failed = [step for step in steps if step["verdict"] != "pass" and step["rate"] > floor]
    if not failed:
        return best, None, "none: the last step passed"
    above = min(failed, key=lambda step: step["rate"])
    if above["verdict"] == "load":
        return best, None, "load"
    return best, above, above["verdict"]


def first_round(steps):
    """The first round's steps: the climb from the lowest rate, whose rates every server shares."""
    return [step for step in steps if step["round"] == 1]


def rounds(steps):
    """Each round's result by `held`, by round: the step held, the step above it that failed,
    and its verdict."""
    numbers = sorted({step["round"] for step in steps})
    return {number: held([step for step in steps if step["round"] == number]) for number in numbers}


def summary(steps):
    """The rounds of a server, as the reports give them: the round whose rate held is the median,
    lower of the two middle ones for an even count, by `held`, with the least and the greatest
    spans a second a round held, and the spans a second of each round. The interval from the
    lowest step held to the highest step that failed above one, or no bound when a round failed
    none, holds the rate the core holds in every round. None, with the first round's verdict,
    when no round held a step."""
    by_round = rounds(steps)
    results = {number: result for number, result in by_round.items() if result[0] is not None}
    if not results:
        return None, next(iter(by_round.values()))[2] if by_round else "no step"
    spans = {number: result[0]["spans"] for number, result in results.items()}
    middle = statistics.median_low(spans.values())
    best, above, verdict = next(result for result in results.values() if result[0]["spans"] == middle)
    tops = [failed["rate"] if failed else float("inf") for _, failed, _ in results.values()]
    return {
        "best": best,
        "above": above,
        "verdict": verdict,
        "low": min(spans.values()),
        "high": max(spans.values()),
        "spans": spans,
        "bottom": min(result[0]["rate"] for result in results.values()),
        "top": max(tops),
    }, verdict


def round_ratios(top, bottom):
    """The ratio of two servers' spans a second held in each round both held a step. Each round
    runs every server once, near in time, so a ratio of one round leaves out a drift of the
    machine between rounds."""
    return [top["spans"][number] / bottom["spans"][number] for number in top["spans"] if number in bottom["spans"]]


def low_latency(steps, limit_ms):
    """The step of the first round with the most spans a second that passed with p99 at most
    `limit_ms`, or None."""
    under = [step for step in first_round(steps) if step["verdict"] == "pass" and step["p99"] <= limit_ms]
    return max(under, key=lambda step: step["spans"]) if under else None


def overlap(first, second):
    """Whether two servers' summaries cannot be told apart: their intervals of rates overlap."""
    return first["bottom"] < second["top"] and second["bottom"] < first["top"]


def bound(top_above, bottom_above):
    """How a ratio of two rates held reads, from the failed step above each: a rate with none is
    a floor, so a ratio of it is at least its value, and a ratio over it at most. Two floors bound
    nothing, and the ratio is marked so."""
    if top_above is None and bottom_above is None:
        return "about "
    if top_above is None:
        return "at least "
    if bottom_above is None:
        return "at most "
    return ""


def resolution(best, above):
    """How far above the rate held the rate the core holds may lie, as a share of the rate held:
    the gap to the lowest step that failed. None when no step above failed."""
    if best is None or above is None:
        return None
    return (above["rate"] - best["rate"]) / best["rate"]


def common_rate(*step_lists):
    """The highest rate that every climb passed, where their costs compare at the same load: a
    span costs less CPU as the rate rises, since each wake of the core serves more calls."""
    rates = None
    for steps in step_lists:
        passed = {step["rate"] for step in steps if step["verdict"] == "pass"}
        rates = passed if rates is None else rates & passed
    return max(rates) if rates else None


def at(steps, rate):
    """The step of a climb at a rate."""
    return next((step for step in steps if step["rate"] == rate), None)


def apart(first, first_above, second, second_above):
    """Whether two climbs held rates the climb tells apart: neither rate lies inside the other's
    interval, from the step held to the step above it that failed."""

    def interval(best, above):
        return best["rate"], above["rate"] if above else float("inf")

    low_first, high_first = interval(first, first_above)
    low_second, high_second = interval(second, second_above)
    return high_first <= low_second or high_second <= low_first


def main():
    """tools/fullstack/climb.py <results> <transport> <server>: the median round's rate held, in
    exports a connection a second, for tools/fullstack/production.sh. Nothing when no round held
    a step."""
    results_path, results_transport, results_server = sys.argv[1:4]
    # The ticks and the seconds set only the CPU shares, which this reads none of.
    result, _ = summary(read(results_path, results_transport, 1, 1)[1].get(results_server, []))
    if result is not None:
        print(f"{result['best']['rate']:g}")


if __name__ == "__main__":
    main()
