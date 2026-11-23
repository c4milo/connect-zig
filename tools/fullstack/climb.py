"""The climbs of tools/fullstack/production.sh, as tools/fullstack's reports read them.

A climb's results hold a line for each step of each server: "step", the transport, the server,
the exports a connection a second, the spans of the calls answered 200, the measured calls a
second and spans a second, p50 and p99 in milliseconds, the calls refused, the verdict, and the
server's CPU ticks over the step. A line "memory" gives the transport, the server and its peak
memory in KiB.
"""
microseconds = 1_000_000
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
        rate, taken, calls, spans, p50, p99, refused, verdict, cpu = fields[3:12]
        steps.setdefault(server, []).append({
            "rate": float(rate), "taken": int(taken), "calls": float(calls), "spans": float(spans),
            "p50": float(p50), "p99": float(p99), "refused": int(refused), "verdict": verdict,
            "busy": int(cpu) / ticks / seconds, "cpu": int(cpu) * microseconds / ticks / max(int(taken), 1),
        })
    return servers, steps, memory


def held(steps):
    """The highest step the server passed, the lowest step above it that failed, and that step's
    verdict. After its first failure, the climb tries rates between, so its steps are not in
    order. The rate the core holds lies between the two steps."""
    passed = [step for step in steps if step["verdict"] == "pass"]
    best = max(passed, key=lambda step: step["rate"]) if passed else None
    floor = best["rate"] if best else 0
    failed = [step for step in steps if step["verdict"] != "pass" and step["rate"] > floor]
    if not failed:
        return best, None, "none: the last step passed"
    above = min(failed, key=lambda step: step["rate"])
    return best, above, above["verdict"]


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
