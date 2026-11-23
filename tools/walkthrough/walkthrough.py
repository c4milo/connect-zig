#!/usr/bin/env python3
"""Records each example's walkthrough and renders it as a GIF beside the example's README.

    python3 tools/walkthrough/walkthrough.py [example...]

For each example it runs the commands its README gives, in the example's folder, for real, and
keeps each command's real output. It writes the session to tools/walkthrough/sessions/<example>.json,
then renders tools/walkthrough/session.html with HyperFrames into examples/<example>/walkthrough.gif.
With no example named, it does all of them.

A command shows as a reader types it. In the run, `zig build` also takes this tree's package
folder and cache, so nothing is fetched again, and `zig build serve` runs in the background on
port 8443 until the session ends. It needs zig, buf, curl and go, and HyperFrames' own needs:
Node 22 or later, FFmpeg and Chrome. HyperFrames runs with its telemetry off.
"""

import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
SESSIONS = ROOT / "tools" / "walkthrough" / "sessions"
TEMPLATE = ROOT / "tools" / "walkthrough" / "session.html"
HYPERFRAMES = "hyperframes@0.9.52"
PORT = "8443"
CA = "../harness/tls/ca.pem"
URL = "https://127.0.0.1:" + PORT
# The seconds each part of a session takes on screen, which session.html reads too.
TIMING = {"lead_s": 0.6, "char_s": 0.03, "enter_s": 0.35, "line_s": 0.07, "pause_s": 1.3, "blink_s": 0.5, "rows": 26}
HOLD_S = 3.0
# The output lines a step shows at most: the first ones, a gap, and the last ones.
HEAD_LINES = 4
TAIL_LINES = 9
FPS = "12"
SERVE_WAIT_S = 120
COMMAND_WAIT_S = 600

# Each example's session: ("run", None) is `zig build run`; ("serve", None) starts
# `zig build serve` in the background; ("sh", text) runs text in a shell.
EXAMPLES = {
    "quickstart": [
        ("sh", "zig build plugin && buf generate && zig build"),
        ("sh", "zig-out/bin/greet-server 8443 ../harness/tls/chain.pem ../harness/tls/key.pem &"),
        ("sh", "zig-out/bin/greet-client 8443 ../harness/tls/ca.pem"),
        ("sh", "curl --cacert " + CA + ' --json \'{"name":"Ada"}\' ' + URL + "/greet.v1.GreetService/Greet"),
    ],
    "protobuf_messages": [("run", None)],
    "sans_io_call": [("run", None)],
    "eliza": [
        ("run", None),
        ("serve", None),
        (
            "sh",
            "curl --cacert "
            + CA
            + ' --json \'{"sentence":"I feel tired"}\' '
            + URL
            + "/connectrpc.eliza.v1.ElizaService/Say",
        ),
        (
            "sh",
            "buf curl --cacert "
            + CA
            + ' --schema proto --protocol grpc -d \'{"name":"Ada"}\' '
            + URL
            + "/connectrpc.eliza.v1.ElizaService/Introduce",
        ),
    ],
    "streaming": [
        ("run", None),
        ("serve", None),
        (
            "sh",
            "buf curl --schema proto --cacert "
            + CA
            + " --data '{\"from\":3}' "
            + URL
            + "/streaming.v1.StreamingService/Countdown",
        ),
        (
            "sh",
            "buf curl --schema proto --cacert "
            + CA
            + ' --data \'{"text":"hello"}{"text":"goodbye"}\' '
            + URL
            + "/streaming.v1.StreamingService/Chat",
        ),
    ],
    "interceptors": [
        ("run", None),
        ("serve", None),
        (
            "sh",
            "curl -i --cacert "
            + CA
            + " -H 'authorization: Bearer Ada' --json '{}' "
            + URL
            + "/interceptors.v1.WhoamiService/Whoami",
        ),
    ],
    "errors": [
        ("run", None),
        ("serve", None),
        (
            "sh",
            "curl --cacert "
            + CA
            + ' --json \'{"dividend":7,"divisor":0}\' '
            + URL
            + "/errors.v1.CalculatorService/Divide",
        ),
    ],
    "github": [
        ("run", None),
        ("serve", None),
        (
            "sh",
            "curl --cacert "
            + CA
            + ' -H \'authorization: Bearer ghp_octocat_example\' --json \'{"name":"hello-world","topics":["zig","rpc"]}\' '
            + URL
            + "/github.v1.RepositoryService/CreateRepository",
        ),
        (
            "sh",
            "curl --cacert "
            + CA
            + ' --json \'{"owner":"octocat"}\' '
            + URL
            + "/github.v1.RepositoryService/ListRepositories",
        ),
    ],
    "oidc": [
        ("run", None),
        ("serve", None),
        (
            "sh",
            "curl --cacert "
            + CA
            + " -H \"authorization: Bearer $TOKEN\" --json '{}' "
            + URL
            + "/account.v1.AccountService/Whoami",
        ),
    ],
    "validate": [
        ("run", None),
        ("serve", None),
        (
            "sh",
            "curl --cacert "
            + CA
            + ' --json \'{"email":"ada@example.com","name":"Ada","age":36}\' '
            + URL
            + "/signup.v1.SignupService/Register",
        ),
        (
            "sh",
            "curl -i --cacert "
            + CA
            + ' --json \'{"email":"ada","name":"Ada","age":7}\' '
            + URL
            + "/signup.v1.SignupService/Register",
        ),
    ],
    "std_io": [
        ("run", None),
        ("serve", None),
        (
            "sh",
            'curl --json \'{"sentence":"I feel tired"}\' http://127.0.0.1:8443/connectrpc.eliza.v1.ElizaService/Say',
        ),
    ],
    "otlp": [
        ("run", None),
        ("serve", None),
        ("sh", "../../interop/otel/run.sh " + URL + " $PWD/../harness/tls/ca.pem"),
    ],
    "socket_server": [
        ("serve", None),
        (
            "sh",
            "curl --cacert " + CA + ' --json \'{"sentence":"Hello"}\' ' + URL + "/connectrpc.eliza.v1.ElizaService/Say",
        ),
        (
            "sh",
            "curl --cacert "
            + CA
            + ' --json \'{"dividend":7,"divisor":2}\' '
            + URL
            + "/errors.v1.CalculatorService/Divide",
        ),
    ],
}

ZIG_FLAGS = ["--system", str(ROOT / "zig-pkg"), "--cache-dir", str(ROOT / ".zig-cache")]


def shown(lines):
    """The lines a step shows: all of them, or the first and the last with a gap between."""
    lines = [line.rstrip() for line in lines if line.strip()]
    if len(lines) <= HEAD_LINES + TAIL_LINES:
        return lines
    return lines[:HEAD_LINES] + ["…"] + lines[-TAIL_LINES:]


def zig(cwd, step, extra):
    return ["zig", "build", step] + ZIG_FLAGS + extra


def actual(text):
    """The command a shell step runs: as shown, with this tree's packages and cache for zig build,
    and curl silent. A terminal shows curl's body alone; a pipe also gets its progress meter."""
    text = re.sub(r"zig build( [a-z]+)?", lambda match: match.group(0) + " " + " ".join(ZIG_FLAGS), text)
    return re.sub(r"(?<!buf )\bcurl ", "curl -sS ", text)


def stop(server):
    """Stops a server and every process it started: `zig build serve` runs the server as a child."""
    try:
        os.killpg(server.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    server.wait()


def record(name):
    """Runs the example's session for real, and returns its steps with their output."""
    cwd = ROOT / "examples" / name
    env = dict(os.environ)
    steps = []
    servers = []
    try:
        for kind, text in EXAMPLES[name]:
            if kind == "run":
                done = subprocess.run(
                    zig(cwd, "run", []),
                    cwd=cwd,
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=COMMAND_WAIT_S,
                    check=False,
                )
                if done.returncode != 0:
                    raise SystemExit(f"{name}: zig build run failed:\n{done.stderr}")
                steps.append({"command": "zig build run", "output": shown((done.stdout + done.stderr).splitlines())})
            elif kind == "serve":
                lines, server = serve(cwd, env, zig(cwd, "serve", ["--", PORT]))
                servers.append(server)
                for line in lines:
                    if line.startswith("token: "):
                        env["TOKEN"] = line[len("token: ") :]
                steps.append({"command": "zig build serve &", "output": shown(lines)})
            elif text.endswith("&"):
                lines, server = serve(cwd, env, ["sh", "-c", actual(text[:-1])])
                servers.append(server)
                steps.append({"command": text, "output": shown(lines)})
            else:
                done = subprocess.run(
                    ["sh", "-c", actual(text)],
                    cwd=cwd,
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=COMMAND_WAIT_S,
                    check=False,
                )
                output = done.stdout + done.stderr
                # Go's HTTP/2 client logs a frame type it does not know, which a peer must
                # ignore (RFC 9113 §4.1); the log line is not the call's output.
                output = "\n".join(line for line in output.splitlines() if "unhandled response frame type" not in line)
                if done.returncode != 0:
                    raise SystemExit(f"{name}: {text} failed:\n{output}")
                steps.append({"command": text, "output": shown(output.splitlines())})
    finally:
        for server in servers:
            stop(server)
    return steps


def serve(cwd, env, command):
    """Starts a server in the background, and returns its lines up to `listening on port`."""
    # The server holds its own copy of the file's descriptor, so this one closes once it starts.
    with tempfile.NamedTemporaryFile("w+", delete=False) as log:
        server = subprocess.Popen(
            command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, text=True, start_new_session=True
        )
    deadline = time.monotonic() + SERVE_WAIT_S
    while time.monotonic() < deadline:
        lines = pathlib.Path(log.name).read_text().splitlines()
        if any(re.match(r"^listening on port \d+$", line) for line in lines):
            return lines, server
        if server.poll() is not None:
            break
        time.sleep(0.1)
    stop(server)
    raise SystemExit(f"{cwd.name}: the server printed no port:\n" + pathlib.Path(log.name).read_text())


def duration(steps):
    """The session's length on screen, as session.html times it, with a hold at the end."""
    at = TIMING["lead_s"]
    for step in steps:
        at += len(step["command"]) * TIMING["char_s"] + TIMING["enter_s"]
        at += len(step["output"]) * TIMING["line_s"] + TIMING["pause_s"]
    return round(at + HOLD_S, 1)


def render(name, steps):
    """Renders the session with HyperFrames into examples/<name>/walkthrough.gif."""
    session = {"title": f"examples/{name} — zsh", "prompt": f"{name} % ", "timing": TIMING, "steps": steps}
    seconds = duration(steps)
    page = TEMPLATE.read_text().replace("__DURATION__", str(seconds)).replace("__SESSION__", json.dumps(session))
    env = dict(os.environ, HYPERFRAMES_NO_TELEMETRY="1", DO_NOT_TRACK="1", HYPERFRAMES_SKIP_SKILLS="1")
    with tempfile.TemporaryDirectory() as scratch:
        project = pathlib.Path(scratch) / "walkthrough"
        subprocess.run(
            [
                "npx",
                "-y",
                HYPERFRAMES,
                "init",
                str(project),
                "--example",
                "blank",
                "--non-interactive",
                "--skip-skills",
            ],
            env=env,
            check=True,
            capture_output=True,
        )
        (project / "index.html").write_text(page)
        output = ROOT / "examples" / name / "walkthrough.gif"
        subprocess.run(
            [
                "npx",
                "-y",
                HYPERFRAMES,
                "render",
                str(project),
                "--format",
                "gif",
                "--fps",
                FPS,
                "--gif-loop",
                "0",
                "--quiet",
                "-o",
                str(output),
            ],
            env=env,
            check=True,
        )
    print(f"{name}: {seconds} s, {output.stat().st_size // 1024} KiB")


def main():
    names = sys.argv[1:] or list(EXAMPLES)
    SESSIONS.mkdir(parents=True, exist_ok=True)
    for name in names:
        steps = record(name)
        (SESSIONS / f"{name}.json").write_text(json.dumps(steps, indent=2, ensure_ascii=False) + "\n")
        render(name, steps)


if __name__ == "__main__":
    main()
