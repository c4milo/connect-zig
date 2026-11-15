# Walkthroughs

Each example's README shows a terminal session of the example: the commands its README gives,
typed, and their real output. [walkthrough.py](walkthrough.py) records and renders them:

```sh
python3 tools/walkthrough/walkthrough.py [example...]
```

For each example it runs the session's commands in the example's folder, for real, and keeps
each command's output. It writes the session to [sessions/](sessions), then renders
[session.html](session.html) with [HyperFrames](https://github.com/heygen-com/hyperframes)
0.9.52 into `examples/<example>/walkthrough.gif`. With no example named, it does all of them.

- A command shows as a reader types it. The run gives `zig build` this tree's package folder and
  cache, so nothing is fetched again, and gives curl `-sS`, since a pipe gets curl's progress
  meter where a terminal does not.
- `zig build serve` runs in the background on port 8443 until the session ends.
- A step shows its first 4 and its last 9 output lines at most.
- `session.html` draws the terminal from the time alone, so HyperFrames may render any frame in
  any order.

It needs zig, buf, curl and go, and what HyperFrames needs: Node 22 or later, FFmpeg and Chrome.
HyperFrames runs with its telemetry off (`HYPERFRAMES_NO_TELEMETRY` and `DO_NOT_TRACK`), and
installs no skill (`--skip-skills`). Run it again when an example's commands or output change.
