//! protovalidate: the check of a message against the rules its schema states with
//! [protovalidate](https://github.com/bufbuild/protovalidate)'s options (docs/decisions.md entry
//! 47). The plugin writes each message's rules as a table beside its descriptor, and `validate`
//! reads the table at comptime. The module allocates nothing, reads no clock and holds no rule
//! at run time: the caller passes the report's storage and the time.
//!
//! ```zig
//! // user.proto: string email = 1 [(buf.validate.field).string.email = true];
//! var storage: [protovalidate.constants.report_bytes_default]u8 align(@alignOf(protovalidate.Violation)) = undefined;
//! var report: protovalidate.Report = .init(&storage);
//! protovalidate.validate(User, &user, .{}, &report) catch |failure| switch (failure) {
//!     error.Invalid => for (report.violations()) |violation| log(violation.rule_id.?, violation.message.?),
//!     else => return failure,
//! };
//! ```
const std = @import("std");

pub const constants = @import("constants.zig");

const files = struct {
    pub const report = @import("report.zig");
    pub const table = @import("table.zig");
    pub const validate = @import("validate.zig");
    pub const check = @import("check.zig");
    pub const interceptor = @import("interceptor.zig");
};

/// The table a generated message declares as `pub const protovalidate`.
pub const Rules = files.table.Rules;
/// The violations of one or more messages, in storage the caller owns.
pub const Report = files.report.Report;
/// One violation: `buf.validate.Violation`, with its field's path, its rule's path, the rule's
/// id and a message.
pub const Violation = files.report.Violation;

/// What `validate` reads beside the message: the time, for a rule that compares with it.
pub const Options = files.validate.Options;
/// What `validate` fails with: `Invalid` for a message that breaks a rule.
pub const Error = files.validate.Error;
pub const validate = files.validate.validate;
/// What stops a type's rules from being checked, which `validate` stops the build with.
pub const rules_error = files.check.rules_error;

/// A server's interceptor that validates each request message, for the `connect` module the
/// program builds with (design §8 step 33).
pub const Interceptor = files.interceptor.Interceptor;
pub const InterceptorOptions = files.interceptor.InterceptorOptions;
/// What the error of a refused message points to, which the route table's `.Values` holds.
pub const InterceptorRoom = files.interceptor.InterceptorRoom;

test "the root exports the names a program calls" {
    try @import("public_names").expect(@This(), &.{
        "constants",   "Rules",              "validate",        "Options", "Report", "Violation", "Error", "rules_error",
        "Interceptor", "InterceptorOptions", "InterceptorRoom",
    });
}

test {
    _ = files.report;
    _ = files.table;
    _ = files.validate;
    _ = files.check;
    _ = files.interceptor;
    _ = @import("refusal_text.zig");
    _ = @import("interceptor_test.zig");
    _ = @import("cel/cel_token.zig");
    _ = @import("cel/cel_literal.zig");
    _ = @import("cel/cel_parse.zig");
    _ = @import("cel/cel_type.zig");
    _ = @import("cel/cel_number.zig");
    _ = @import("cel/cel_select.zig");
    _ = @import("cel/cel_function.zig");
    _ = @import("cel/cel_value.zig");
    _ = @import("cel/cel_time.zig");
    _ = @import("cel/cel_eval_test.zig");
    _ = @import("cel/cel_rule.zig");
    _ = @import("cel/cel_rule_test.zig");
    _ = @import("shape.zig");
    _ = @import("text.zig");
    _ = @import("rule_number.zig");
    _ = @import("rule_scalar.zig");
    _ = @import("rule_string.zig");
    _ = @import("rule_bytes.zig");
    _ = @import("rule_time.zig");
    _ = @import("rule_field_mask.zig");
    _ = @import("format_name.zig");
    _ = @import("format_ip.zig");
    _ = @import("format_uri.zig");
    _ = @import("validate_test.zig");
    _ = @import("walk_test.zig");
    _ = @import("rule_test.zig");
    _ = @import("rule_wkt_test.zig");
}
