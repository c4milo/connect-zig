//! The oidc module's named sizes.

/// The longest token `Verifier.verify` reads, in characters. A route copies at most this many
/// octets of request headers (`connect_colibri.constants.request_header_bytes`), so a longer
/// token never reaches a handler.
pub const token_bytes_max = 4096;
/// The octets a token's three parts decode to, at most. Base64url writes 4 characters for each 3
/// octets (RFC 4648 §5), and the three parts together hold at most `token_bytes_max` characters.
pub const decoded_bytes_max = token_bytes_max / 4 * 3;
/// The keys a verifier holds, at most. An issuer publishes the key it signs with and the keys it
/// retires or brings in: two to four in practice.
pub const keys_max = 8;
/// The longest key identifier, a JWK's "kid" (RFC 7517 §4.5), that the verifier keeps. A key with
/// a longer one is not kept, and a token with a longer one names no key.
pub const key_id_bytes_max = 128;
/// The shortest and the longest RS256 modulus, in octets: RFC 7518 §3.3 requires a key of 2048
/// bits or more, and chapulin's `CH_JWS_RSA_MODULUS_LEN_MAX` is RSA-4096.
pub const rsa_modulus_bytes_min = 256;
pub const rsa_modulus_bytes_max = 512;
/// The longest RS256 public exponent, in octets: chapulin's `CH_JWS_RSA_EXPONENT_LEN_MAX`.
pub const rsa_exponent_bytes_max = 8;
/// The octets of a P-256 coordinate (RFC 7518 §6.2.1.2) and of an Ed25519 public key (RFC 8037
/// §2).
pub const coordinate_bytes = 32;
/// The octets of the longest key in the form chapulin's `jws.verify` takes: RFC 3110 §2's form
/// of an RSA key, which is one octet of exponent length, the exponent and the modulus.
pub const key_bytes_max = 1 + rsa_exponent_bytes_max + rsa_modulus_bytes_max;
/// The longest issuer and the longest audience `Verifier.init` copies, in octets.
pub const issuer_bytes_max = 255;
pub const audience_bytes_max = 255;
/// The longest subject, in octets: OpenID Connect Core 1.0 §2 holds "sub" to 255 ASCII
/// characters.
pub const subject_bytes_max = 255;
/// The longest string a lookup of `Claims` returns, and the longest name it looks for. An email
/// address holds 254 octets at most (RFC 5321 §4.5.3.1.3), and a role or a group far fewer.
pub const claim_bytes_max = 1024;
/// The longest leeway, in seconds, that `Verifier.init` takes for the time claims. RFC 7519
/// §4.1.4 allows "no more than a few minutes" for clock skew.
pub const leeway_s_max = 300;
/// The digits of a NumericDate's whole seconds (RFC 7519 §2), at most. Twelve digits reach past
/// the year 30000.
pub const numeric_date_digits_max = 12;
/// The nesting of a JSON value the readers pass over, at most.
pub const json_depth_max = 16;
/// The octets of token storage a JSON reader needs, at least: room for one character in UTF-8
/// (RFC 3629 §3), so each call of the decoder takes input.
pub const reader_storage_bytes_min = 4;
/// The paths one `Interceptor` excludes, at most.
pub const excluded_paths_max = 32;
