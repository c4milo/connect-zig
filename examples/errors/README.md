# Errors

`errors.v1.CalculatorService/Divide`, which fails with a typed detail when the divisor is 0:
`invalid_argument`, with an `errors.v1.DivisionByZero` that holds the dividend. The check reads
the error and its detail in Connect, gRPC and gRPC-Web, and calls a method the service does not
have, which answers `unimplemented`.

![A terminal session: zig build run checks the typed errors, then curl divides by zero and reads the DivisionByZero detail](walkthrough.gif)

## Files

| Path | Holds |
| --- | --- |
| [proto/errors/v1/errors.proto](proto/errors/v1/errors.proto) | The schema, with the `DivisionByZero` detail |
| [src/service/service.zig](src/service/service.zig) | Divide, and the `Counting` interceptor, whose counts go out as trailers |
| [src/app.zig](src/app.zig) | This example's `App` and route table |
| [src/main.zig](src/main.zig) | The check, over h2 and h3 |
| [src/serve.zig](src/serve.zig) | The same routes on a socket, to play with |

## Run it

```sh
zig build run
```

## Play with it

```sh
zig build serve
```

From this folder:

```sh
curl --cacert ../harness/tls/ca.pem --json '{"dividend":7,"divisor":2}' \
  https://127.0.0.1:8443/errors.v1.CalculatorService/Divide
curl -i --cacert ../harness/tls/ca.pem --json '{"dividend":7,"divisor":0}' \
  https://127.0.0.1:8443/errors.v1.CalculatorService/Divide
```

The first answers `{"quotient":"3","remainder":"1"}`. The second fails with HTTP 400:

```json
{"code":"invalid_argument","message":"division by zero","details":[{"type":"errors.v1.DivisionByZero","value":"CAc"}]}
```

The detail's value is the `DivisionByZero` in binary, base64: `CAc` is field 1, dividend 7.
