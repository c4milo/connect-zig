# Security policy

## How to report a vulnerability

Use GitHub's private vulnerability reporting: open the repository's
[Security tab](https://github.com/c4milo/connect-zig/security) and click "Report a
vulnerability". The report stays private, and the advisory and CVE, if one is warranted, come out
of the same thread.

If you cannot use GitHub, email camilo.aguilar@gmail.com with the same details you would put in
the report.

Do not open a public issue for a vulnerability.

## What to expect

One maintainer runs this project. You get an acknowledgment within 7 days, and an assessment
within 30: confirmed, not a vulnerability, or more information needed. The fix date comes out of
the assessment.

## Scope

In scope: the library modules under `src/` (`protobuf`, `connect` and `connect_colibri`), which
read a peer's octets, and the code `protoc-gen-connect-zig` writes. A peer's input that makes
connect-zig crash, trip an assertion, read or write outside a buffer, loop without bound, or
accept a message the Connect protocol, gRPC's documents or the protobuf encoding guide require it
to refuse is a vulnerability.

Out of scope, so triage stays fast:

- `examples/`, `conformance/`, `interop/`, `bench/` and `tools/`, which are programs and checks
  that ship in no package. The key in `examples/testdata/tls` is public and for tests alone.
- Attacks that need a malicious caller: a wrong buffer, a wrong instant, or a handler that lies.
  The caller is trusted; the peer and the network are not.
- Denial of service through the caller's own limits. connect-zig names every limit as a
  constant, and the caller owns its timeouts and its event loop.
- Weaknesses in colibri, stdx or chapulin. Report those to
  [colibri](https://github.com/c4milo/colibri/security),
  [stdx](https://github.com/c4milo/stdx/security) or
  [chapulin](https://github.com/c4milo/chapulin/security).

[`docs/decisions.md`](docs/decisions.md) records what connect-zig refuses to build and why.
