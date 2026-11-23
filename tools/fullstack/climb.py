"""The climbs of tools/fullstack/production.sh, as tools/fullstack's reports read them.

A climb's results hold a line for each step of each server: "step", the transport, the server,
the exports a connection a second, the spans of the calls answered 200, the measured calls a
second and spans a second, p50 and p99 in milliseconds, the measured calls refused, the verdict,
the calls refused in the step's first seconds, which the measure leaves out, the share of the
load's cores that was busy, -1 with no core pinned, the server's CPU ticks over the step, and the
step's wall time in milliseconds. A line "memory" gives the transport, the server and its peak
memory in KiB, and a line "suite" the transport, the server and the TLS 1.3 suite it chose.
"""
microseconds = 1_000_000
milliseconds = 1000
kib = 1024


def read(path, transport, ticks, seconds):
    """The servers in the order the file names them, each server's steps, and each server's peak
    memory in MiB, for the lines of `transport`."""
    servers, steps, memory = [], {}, {}
    for line in open(path):
        fields = line.split()
        if len(fields) < 3 or fields[1] != transport:
            continue
        server = fields[2]
        if server not in servers:
            servers.append(server)
        if fields[0] == "memory":
            memory[server] = int(fields[3]) / kib
            continue
        if fields[0] != "step":
            continue
        rate, taken, calls, spans, p50, p99, refused, verdict, warm_refused, load, cpu, wall_ms = fields[3:15]
        steps.setdefault(server, []).append({
            "rate": float(rate), "taken": int(taken), "calls": float(calls), "spans": float(spans),
            "p50": float(p50), "p99": float(p99), "refused": int(refused), "verdict": verdict,
            "warm_refused": int(warm_refused), "load": float(load),
            # The share of a core over the step's measured wall time, which passes its nominal
            # seconds by oha's start and end.
            "busy": int(cpu) / ticks / max(int(wall_ms) / milliseconds, seconds),
            "cpu": int(cpu) * microseconds / ticks / max(int(taken), 1),
        })
    return servers, steps, memory


def suites(path, transport):
    """The TLS 1.3 suite each server chose, by server, from the lines of `transport`."""
    found = {}
    for line in open(path):
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
