#!/usr/bin/env python3
"""Chooses the CPUs of tools/fullstack_check.sh from Linux's CPU topology, so the server and the
load never share a physical core.

    tools/fullstack/placement.py [sysfs root]

It prints one line: the server's CPU, the load's CPUs joined by commas, and the threads of one
core. CPU 0 runs the scripts. Where a core holds one thread, the server takes CPU 1 and the load
CPUs 2 and 3. Where a core holds two, as on a runner with SMT, the server takes CPU 0's sibling,
whose core runs the scripts beside it, and the load takes the two threads of another core. With
fewer than 4 CPUs it prints `- - <threads>`, and nothing is pinned.
"""

import os
import sys

cpus_needed = 4
load_cpus = 2


def cpus_of(text):
    """The CPUs of a list such as `0-3` or `0,2,4-5`."""
    found = []
    for part in text.strip().split(","):
        low, _, high = part.partition("-")
        found += range(int(low), int(high or low) + 1)
    return found


def read(root, path):
    with open(os.path.join(root, path)) as file:
        return file.read()


def placement(online, core0):
    """The line the script prints, from the CPUs online and the threads of CPU 0's core."""
    if len(online) < cpus_needed:
        return f"- - {len(core0)}"
    if len(core0) > 1:
        server = min(cpu for cpu in core0 if cpu != 0)
        load = [cpu for cpu in online if cpu not in core0][:load_cpus]
        return f"{server} {','.join(map(str, load))} {len(core0)}"
    return "1 2,3 1"


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "/sys/devices/system/cpu"
    online = cpus_of(read(root, "online"))
    print(placement(online, cpus_of(read(root, "cpu0/topology/thread_siblings_list"))))


if __name__ == "__main__":
    main()
