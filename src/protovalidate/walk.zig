//! What every file of the walk shares: its state, what ends it, and how a broken rule is
//! written into the report (decision 47).
const std = @import("std");
const codec = @import("codec");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const report_file = @import("report.zig");
const table = @import("table.zig");

pub const Path = report_file.Path;
pub const Element = table.Element;

pub const Options = struct {
    /// The CPU features that `pattern` and CEL's `matches` may search with. The module probes no
    /// CPU (decision 47): a program detects them once as it starts, with `codec.Features.detect()`,
    /// and passes the value to each call. `codec.Features.target()` names what the build target
    /// guarantees, and `codec.Features.none()` keeps every search on its plain path.
    cpu_features: codec.Features,
    /// The time a rule such as `timestamp.lt_now` compares with. The module reads no clock
    /// (decision 3): a message whose rules read the time fails with `TimeMissing` without it.
    now: ?proto.wkt.Timestamp = null,
};

pub const Error = error{
    /// The message breaks a rule. The report holds each violation it had room for.
    Invalid,
    /// A rule reads the time, and `Options.now` is null.
    TimeMissing,
    /// A message nests deeper than `constants.path_depth_max`.
    TooDeep,
    /// A repeated field with `unique`, or a map with `min_pairs`, holds more elements than
    /// the module compares pair by pair: `constants.compared_items_max`.
    TooManyItems,
    /// A repeated field's or a nested message's octets do not decode: `decode` never read
    /// the message.
    Malformed,
    /// A CEL rule's expression failed as it ran, such as by a division by zero: the rule
    /// gave no verdict.
    Unevaluable,
};

/// What ends a walk early: an error `validate` returns, or a report with no room left.
pub const Fault = error{ ReportFull, TimeMissing, TooDeep, TooManyItems, Malformed, Unevaluable };

pub const Walk = struct {
    report: *report_file.Report,
    /// The caller's options, which last as long as `validate` runs. A pointer, so a walk copies
    /// none of them.
    options: *const Options,
    /// The messages the walk is inside of.
    depth: usize = 0,
};

/// Where a value lies among a field's rules: the path from `buf.validate.FieldRules` to the
/// rules that apply to it. A field's own value has no prefix, an element of a repeated field
/// has `repeated.items`, and a map's key has `map.keys`.
pub const Site = struct {
    prefix: []const Element = &.{},
    /// Whether the value is a map entry's key.
    for_key: bool = false,
    /// The predefined rules of the extensions that the rules at this site hold.
    predefined: []const table.Rules.Predefined = &.{},
};

/// A rule that a value broke: what its violation states beside the field.
pub const Broken = struct {
    rule: ?pb.FieldPath = null,
    id: []const u8,
    message: []const u8,
};

/// The violation of the rule `rule` of the rule message `Rules`, which FieldRules holds as its
/// member `kind`, under the id `kind.id`: "string.min_len", "int32.gt_lt".
pub fn rule_broken(comptime Rules: type, comptime kind: []const u8, comptime site: Site, comptime rule: []const u8, comptime id: []const u8, comptime message: []const u8) Broken {
    return .{
        .rule = table.rule_path(site.prefix, &.{ .{ .message = pb.FieldRules, .name = kind }, .{ .message = Rules, .name = rule } }),
        .id = kind ++ "." ++ id,
        .message = message,
    };
}

/// Writes the violation of `broken` by the value at `path`, and ends the walk when the report
/// has no room for it.
pub fn violate(walk: *Walk, path: ?*const Path, comptime broken: Broken, comptime for_key: bool) Fault!void {
    const entry: report_file.Entry = comptime .{ .rule = broken.rule, .rule_id = broken.id, .message = broken.message, .for_key = for_key };
    if (!report_file.add(walk.report, path, entry)) return error.ReportFull;
}

/// Writes a violation whose message the run gave: a CEL rule's own text. A text that `format`
/// wrote into the report's room is kept in the report's storage; any other is comptime data,
/// or text of the message `validate` read.
pub fn violate_text(walk: *Walk, path: ?*const Path, comptime rule: ?pb.FieldPath, comptime id: []const u8, message: []const u8, comptime for_key: bool, comptime formats: bool) Fault!void {
    const entry: report_file.Entry = .{ .rule = rule, .rule_id = id, .message = message, .for_key = for_key };
    const added = if (formats) report_file.add_text(walk.report, path, entry) else report_file.add(walk.report, path, entry);
    if (!added) return error.ReportFull;
}

/// The `Malformed` fault for any error of the protobuf module's readers: octets that `decode`
/// would have refused.
pub fn malformed(_: anyerror) Fault {
    return error.Malformed;
}
