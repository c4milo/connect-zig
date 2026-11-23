"""The machine line of tools/fullstack's reports: the CPU's model as lscpu names it, the CPUs and
the threads of one core, which say whether a core runs two CPUs, and the kernel."""
import os
import subprocess


def machine():
    found = subprocess.run(["lscpu"], capture_output=True, text=True).stdout
    model = next((line.split(":", 1)[1].strip() for line in found.splitlines() if line.startswith("Model name:")), "unknown")
    threads = next((line.split(":", 1)[1].strip() for line in found.splitlines() if line.startswith("Thread(s) per core:")), "?")
    unit = "thread" if threads == "1" else "threads"
    return f"{model}, {os.cpu_count()} CPUs, {threads} {unit} a core, Linux {os.uname().release}"
