# std.Io

ELIZA on colibri's `server.Engine`, driven over Zig 0.16's `std.Io` alone, with no Rotor
(decision 32), and a client that calls it over TCP with a `client.ConnectionPool` it also drives
over `std.Io`. The library takes octets and gives octets back, so any loop can run it.

![A terminal session: zig build run calls the std.Io server over TCP, then curl calls ELIZA in cleartext](walkthrough.gif)

The server's task owns the engine. An acceptor task, a reader task for each socket and a ticker
only wait, and each sends what it got to the owner through one bounded `std.Io.Queue`. The owner
hands it to the engine and writes what the engine owes. The ticks fire the engine's deadlines, at
most 50 ms late. It serves h11 and h2 with prior knowledge in cleartext, with no TLS and no h3.

## Files

| Path | Holds |
| --- | --- |
| [src/server/server.zig](src/server/server.zig) | The server and its tasks |
| [src/client/client.zig](src/client/client.zig) | The check: it starts the server on port 0 and calls it |
| [src/client/driver.zig](src/client/driver.zig) | The client's loop over a TCP socket |

The project serves the ELIZA service of [eliza](../eliza), which it depends on by path. It
passes connect-zig, eliza and the harness `.rotor = false`, so its build holds one connect-zig
and no Rotor.

## Run it

```sh
zig build run
```

The check runs a round over h2 and a round over h11, then checks that a socket that sends
nothing closes at the server's first-request deadline, which only the ticks fire.

## Play with it

```sh
zig build serve -- 8080
curl --json '{"sentence":"I feel tired"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
```
