//! The `protovalidate` module's named sizes.

/// The deepest a violation's field lies: one path element for each message the field nests in.
/// `decode` follows messages 100 deep (`protobuf.constants.limits.depth_max`), so no decoded
/// message nests deeper, and a message a program built deeper fails with `TooDeep`.
pub const path_depth_max = 100;
/// The octets of a report that holds about 16 violations of fields one message deep: a
/// violation takes 184 octets and each element of its field's path 96.
pub const report_bytes_default = 4096;
/// The octets of the `buf.validate.Violations` an interceptor's error carries by default. gRPC
/// writes an error's details in base64 in its trailers, and gRPC-Web writes those twice, so a
/// transport that keeps 16 KiB for a call's trailers holds this detail with room for the rest.
pub const detail_bytes_default = 2048;
/// The octets of the message of an interceptor's error, at most: the first violation's field
/// and what it broke. A longer text gives way to the violation's own message.
pub const refusal_message_len_max = 256;
/// The backward branches the compiler may take for each rule of a field while it reads a
/// message's table: it compares the octets of names to find the rule's descriptor, and writes
/// the rule's value into its message. The compiler counts the branches of one function's
/// analysis together, so a function that reads many rules needs room for all of them.
pub const eval_branches_per_rule = 200_000;
/// The most elements of a repeated field with `unique`, and the most entries of a map, that the
/// module compares pair by pair: it holds no set, so 1024 elements take about half a million
/// comparisons. A longer `unique` list fails with `TooManyItems`, and a longer map is read entry
/// by entry (`map.zig`).
pub const compared_items_max = 1024;
/// The nanoseconds of one second, which a duration's and a timestamp's `nanos` count up to
/// (google/protobuf/duration.proto).
pub const nanos_per_second = 1_000_000_000;
/// The octets of an IPv4 address, of an IPv6 address and of a UUID, which `bytes.ip`,
/// `bytes.ipv4`, `bytes.ipv6` and `bytes.uuid` compare a value's length with (validate.proto,
/// BytesRules).
pub const ipv4_len = 4;
pub const ipv6_len = 16;
pub const uuid_len = 16;
/// The longest hostname, without its trailing dot, and the longest label of one (validate.proto,
/// StringRules.hostname).
pub const hostname_len_max = 253;
pub const hostname_label_len_max = 63;
/// The most digits of a port, whose largest value is 65535 (validate.proto,
/// StringRules.host_and_port).
pub const port_digits_max = 5;
/// The base of a decimal number, and of a hexadecimal one.
pub const decimal_base = 10;
pub const hexadecimal_base = 16;
/// The characters of a UUID with its four hyphens, where each hyphen lies, and the characters
/// of a UUID without them and of a ULID (validate.proto, string.uuid, string.tuuid and
/// string.ulid).
pub const uuid_text_len = 36;
pub const uuid_hyphens = [_]usize{ 8, 13, 18, 23 };
pub const tuuid_text_len = 32;
pub const ulid_text_len = 26;
/// The most digits of an IPv4 address's octet, the groups of an IPv6 address, the most digits
/// of one group, and the most digits of a prefix length, whose largest value is 128 (RFC 3986
/// §3.2.2).
pub const dec_octet_digits_max = 3;
pub const ipv6_groups = 8;
pub const h16_digits_max = 4;
pub const prefix_len_digits_max = 3;
/// The hexadecimal digits of a pct-encoded octet, after its "%" (RFC 3986 §2.1), and the most
/// octets of one UTF-8 sequence (RFC 3629 §3).
pub const pct_encoded_digits = 2;
pub const utf8_sequence_len_max = 4;
