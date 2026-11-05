//! The test-only TLS identity of the examples' h3 rounds (decision 25): a P-256 CA, and a leaf for
//! `localhost` and 127.0.0.1 that the CA signs, as the PEM files an operator holds (RFC 7468).
//! `tools/test_identity.sh` mints them, and README.md says how. `@embedFile` reads only inside the
//! directory of the module that calls it, so the identity is a module of its own, as colibri's
//! test identity is. The key is for tests alone: no module of `src/` imports this one.
const std = @import("std");
const assert = std.debug.assert;

/// The leaf's certificate, then the CA's: the chain the server presents.
pub const chain_pem = @embedFile("chain.pem");
/// The leaf's P-256 key, as a PKCS #8 `PRIVATE KEY` block (RFC 5958).
pub const key_pem = @embedFile("key.pem");
/// The CA's certificate alone: the bundle a client reads its trust anchor from.
pub const ca_pem = @embedFile("ca.pem");

/// The name the leaf carries, which a client asks for and judges the certificate by.
pub const server_name = "localhost";

/// The first and the last instant both certificates are valid at, in Unix seconds: their notBefore,
/// 2020-01-01T00:00:00Z, and their notAfter, 2099-12-31T23:59:59Z.
pub const not_before_seconds: u64 = 1_577_836_800;
pub const not_after_seconds: u64 = 4_102_444_799;

/// The instant the examples judge the chain at, in Unix seconds: 2027-01-15T08:00:00Z. A program
/// reads it from its clock.
pub const now_seconds: u64 = 1_800_000_000;

comptime {
    assert(not_before_seconds <= now_seconds and now_seconds <= not_after_seconds);
}
