# OpenID Connect

`account.v1.AccountService` behind `oidc.Interceptor`, which checks OpenID Connect bearer tokens
with no I/O (decision 34): a JWT signed with RS256, ES256 or EdDSA, then its issuer, its audience
and its times.

- `Status` needs no token, since the interceptor excludes its path.
- `Whoami` needs a valid token, and answers with its claims.
- A call with no token, an expired one, or one for another audience is refused with
  `unauthenticated` and RFC 6750's `WWW-Authenticate: Bearer` challenge.

A test issuer stands where the OpenID provider would be. It holds two keys, writes their JWK Set
and signs the tokens. Between the check's two rounds it changes its key: the verifier refuses the
new key's token, reports its keys stale, takes the new JWK Set, and then takes the same token.

## Files

| Path | Holds |
| --- | --- |
| [proto/account/v1/account.proto](proto/account/v1/account.proto) | The schema |
| [src/service/service.zig](src/service/service.zig) | The service behind `oidc.Interceptor`, and `start`, which starts the verifier |
| [src/service/issuer.zig](src/service/issuer.zig) | The test issuer: its keys, their JWK Set, and the tokens it signs |
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

The server prints a line `token: <jwt>` at the start: a token for "ada" that the test issuer
signs, valid for an hour. Copy it, then from this folder:

```sh
curl --cacert ../harness/tls/ca.pem --json '{}' \
  https://127.0.0.1:8443/account.v1.AccountService/Status
curl --cacert ../harness/tls/ca.pem -H "authorization: Bearer $TOKEN" --json '{}' \
  https://127.0.0.1:8443/account.v1.AccountService/Whoami
curl -i --cacert ../harness/tls/ca.pem --json '{}' \
  https://127.0.0.1:8443/account.v1.AccountService/Whoami
```

The first answers `{"status":"ok"}`, the second `{"subject":"ada","email":"ada@example.com",
"admin":true}`, and the third 401 with `www-authenticate: Bearer`.

The server reads its clock once, at the start. A server that runs for long calls `set_time` again
as its clock moves, and `set_keys` when `keys_stale` asks for the provider's keys again.
