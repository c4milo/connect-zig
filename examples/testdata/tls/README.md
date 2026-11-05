# The test identity

The TLS identity of the examples' h3 rounds (decision 25). It is for tests alone: anyone can
read the private key here, so no program outside the examples may present it.

| File | Holds |
| --- | --- |
| `ca.pem` | The CA's certificate, `CN=connect-zig test CA`: the bundle the client trusts |
| `chain.pem` | The leaf's certificate, then the CA's: the chain the server presents |
| `key.pem` | The leaf's P-256 key, as a PKCS #8 `PRIVATE KEY` block (RFC 5958) |
| `identity.zig` | The module that embeds the three files, and the instants they are valid at |

Both certificates are valid from 2020-01-01T00:00:00Z to 2099-12-31T23:59:59Z. The examples judge
them at the fixed instant 1_800_000_000, 2027-01-15. They have the profile of colibri's own test
identity, which chapulin's Web PKI mode accepts:

- Both keys are P-256, and both certificates are signed with ecdsa-with-SHA256.
- The CA has serial 1, a critical keyUsage of digitalSignature and keyCertSign, a critical
  basicConstraints of `CA:TRUE`, and a subjectKeyIdentifier.
- The leaf has serial 2, `CN=localhost`, a critical keyUsage of digitalSignature, an
  extendedKeyUsage of serverAuth, a critical basicConstraints of `CA:FALSE`, an
  authorityKeyIdentifier that names the CA's key, and a subjectAltName of `DNS:localhost` and
  `IP:127.0.0.1`.
- notBefore is a UTCTime and notAfter a GeneralizedTime. chapulin reads a year before 2050 only
  as a UTCTime, and a year from 2050 on only as a GeneralizedTime.

## Mint it again

```sh
tools/test_identity.sh
```

The script runs `openssl ca` in a temporary directory and copies the three PEM files here. The
CA's key is not kept. Each run mints new keys, so every file changes. OpenSSL 3.0.13 made the
files committed here. `OPENSSL` names another openssl binary.
