# A call with no socket

Two whole calls through the `connect` module alone: no socket, no HTTP library, no Rotor. The
program plays both sides. Its client writes a request's path, headers and body; its server reads
them, runs the handler and writes the response; the client then reads the answer. This is what
`connect_colibri` does for colibri, and what a program does for any other HTTP library.

- `Say`, unary, over Connect in JSON;
- `Introduce`, a server stream, over gRPC-Web, whose messages come back in envelopes.

The project uses the ELIZA schema of [eliza](../eliza), which it depends on by path.

## Run it

```sh
zig build run
```
