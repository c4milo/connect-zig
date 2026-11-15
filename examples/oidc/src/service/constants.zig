//! The account service's limits, and the test issuer's (decision 42).

/// The longest message a route of the service reads or writes, and its longest JSON token.
pub const message_len_max = 4096;
/// The seconds the service's clock may differ from the issuer's.
pub const leeway_s = 30;

/// The longest JWK Set and the longest token the test issuer writes.
pub const jwks_len_max = 1024;
pub const token_len_max = 1024;
/// SEC 1 §2.3.3: an uncompressed point is one octet, then X, then Y, 32 octets each on P-256.
pub const coordinate_len = 32;
/// The octets of the seed that makes a P-256 key.
pub const seed_len = 32;
/// The seed octet of the issuer's first key, and of the key it moves to later.
pub const first_seed = 1;
pub const second_seed = 2;
