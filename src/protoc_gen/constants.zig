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
/// The names that lead to a rule message of a field's own rules, the field and its type, as
/// "val.float" is: the fewest a rule message of a field has.
pub const own_rules_path_len = 2;
/// The most `.of(` calls a table's literal makes under the compiler's own quota. The compiler
/// counts each call of a declaration's value against its branch quota, 1000 unless the
/// declaration raises it, so a table with more calls raises it.
pub const table_calls_unraised_max = 500;
/// The compiler's branch quota for a declaration that sets none (Zig language reference,
/// `@setEvalBranchQuota`), and the branches a table's quota adds for each call of its literal.
pub const branches_default = 1000;
pub const branches_per_call = 2;
/// The name in `RuleNumber` of the branch quota of a table that raises it. No rule's name
/// starts with a dot but a message rule's, which starts with ".message".
pub const branches_name = ".branches";
/// The declaration of a generated message that holds its rules: `protovalidate.Rules`.
pub const rules_declaration = "protovalidate";
