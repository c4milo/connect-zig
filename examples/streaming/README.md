# Streaming

Every kind of stream, in `streaming.v1.StreamingService`:

- `Chat`, a bidirectional stream, whose handler is a type that answers each message as it
  arrives, so over h2 and h3 the stream is full-duplex;
- `Sum`, a client stream, which a type handler adds up as the numbers arrive;
- `Countdown`, a server stream of any length, whose handler gives one number at a time with
  `next` (decision 33).

## Files

| Path | Holds |
| --- | --- |
| [proto/streaming/v1/streaming.proto](proto/streaming/v1/streaming.proto) | The schema |
| [src/service/service.zig](src/service/service.zig) | The three handlers, and the `Counting` interceptor on Chat |
| [src/app.zig](src/app.zig) | This example's `App` and route table |
| [src/main.zig](src/main.zig) | The check: each stream, a stream that fails, and a refused one, over h2, h11 and h3 |
| [src/duplex.zig](src/duplex.zig) | The full-duplex rounds, where the client sends each message with its `Sender` |
| [src/serve.zig](src/serve.zig) | The same routes on a socket, to play with |

## Run it

```sh
zig build run
```

## Play with it

```sh
zig build serve
```

Each method streams, so `buf curl` is the simple client. From this folder:

```sh
buf curl --schema proto --cacert ../harness/tls/ca.pem --data '{"from":3}' \
  https://127.0.0.1:8443/streaming.v1.StreamingService/Countdown
buf curl --schema proto --cacert ../harness/tls/ca.pem --data '{"number":1}{"number":2}{"number":3}' \
  https://127.0.0.1:8443/streaming.v1.StreamingService/Sum
buf curl --schema proto --cacert ../harness/tls/ca.pem --data '{"text":"hello"}{"text":"goodbye"}' \
  https://127.0.0.1:8443/streaming.v1.StreamingService/Chat
```

Countdown answers 3, 2 and 1; Sum answers `{"sum":"6","count":"3"}`; Chat answers each line.
curl sends a stream too, when each message has its Connect envelope:

```sh
printf '\000\000\000\000\012{"from":3}' | curl --cacert ../harness/tls/ca.pem \
  -H 'content-type: application/connect+json' --data-binary @- --output - \
  https://127.0.0.1:8443/streaming.v1.StreamingService/Countdown
```
