# The harness

A package, not an example (decision 41). It stands where a program's sockets, certificate and
clock would be, so each example can check itself in one process. The examples depend on it by
path: `.harness = .{ .path = "../harness" }`.

| Module or file | Holds |
| --- | --- |
| `harness`, [src/harness.zig](src/harness.zig) | The module's root |
| [src/rounds.zig](src/rounds.zig) | `Rounds(App, Router)`: a client and a server that run a round of calls in memory, over h11, h2 or h3 |
| [src/call.zig](src/call.zig) | `Call(method, options)`: a client call with the buffers it writes and reads in |
| [src/serve.zig](src/serve.zig) | `Served(App, Router)`: an example's routes on a real socket, for `zig build serve` |
| [src/link.zig](src/link.zig), [src/link_datagram.zig](src/link_datagram.zig) | colibri's in-memory links for octet streams and for datagrams, copied unchanged |
| `test_identity`, [tls/](tls) | The test-only TLS identity: a CA, and a leaf for `localhost` and 127.0.0.1 (decision 25) |
| `hooks`, [src/hooks.zig](src/hooks.zig) | chapulin's hook, for a program with no Rotor |

A program allocates its `Rounds` once, with the rest of its state (decision 42):

```zig
const Rounds = harness.Rounds(App, Router);
try state.rounds.init(&state.app);
try state.rounds.begin(.{ .h11 = false, .h3 = false });
try state.rounds.request(&call.call.request, &call.call.response);
try state.rounds.finish(.h2);
```

A round over h2 or h11 runs TCP in cleartext over the stream link, h2 with prior knowledge. A
round over h3 runs QUIC over the datagram link, and the client trusts the test CA. Both judge the
certificates at the fixed instant 1_800_000_000, which a real program reads from its clock.

The build option `rotor`, true by default, goes to connect-zig. A project with no Rotor, as
`std_io` is, passes `.rotor = false` and imports `hooks` alone, since the `harness` module runs on
Rotor.
