"""The machine line of tools/fullstack's reports: the CPU's model as lscpu names it, the cores,
and the kernel."""
import os
import subprocess


def machine():
    found = subprocess.run(["lscpu"], capture_output=True, text=True).stdout
    model = next((line.split(":", 1)[1].strip() for line in found.splitlines() if line.startswith("Model name:")), "unknown")
    return f"{model}, {os.cpu_count()} cores, Linux {os.uname().release}"
