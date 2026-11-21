//! The plugin's named sizes.

/// The most bytes of request the plugin reads: protoc's requests for large trees stay far below.
pub const request_len_max = 256 * 1024 * 1024;
/// The bytes stdin and stdout each buffer.
pub const io_buffer_len = 64 * 1024;
/// The largest number a rule's literal holds in place. A larger one is a constant of the
/// message's `RuleNumber`: the magic-numbers rule takes 0 and 1 as structure, and reads the code
/// the plugin writes (decision 17).
pub const unnamed_number_max = 1;
/// The declaration of a generated message that names the numbers of its rules.
pub const rule_number_container = "RuleNumber";
/// The declaration of a generated message that holds its rules: `protovalidate.Rules`.
pub const rules_declaration = "protovalidate";
