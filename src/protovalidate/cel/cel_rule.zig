//! The CEL rules of a message and of a field: `cel` and `cel_expression` (validate.proto, Rule,
//! MessageRules and FieldRules). Each rule's expression gives a bool, where false breaks the
//! rule, or a string, where a string that is not empty breaks it and is the violation's
//! message.
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("../table.zig");
const walk_file = @import("../walk.zig");
const report_file = @import("../report.zig");
const program = @import("cel_program.zig");
const type_file = @import("cel_type.zig");
const list_file = @import("cel_list.zig");
const shape = @import("../shape.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;
const Scope = type_file.Scope;

/// One rule as the walk reads it: a `cel` rule, or a `cel_expression` under its own text.
const Rule = struct {
    /// The rule's field in its rule message: "cel" or "cel_expression".
    field: []const u8,
    index: usize,
    id: []const u8,
    message: []const u8,
    expression: []const u8,
};

/// The CEL rules of `rules`, a `buf.validate.FieldRules` or a `buf.validate.MessageRules`.
fn rules_of(comptime rules: anytype) []const Rule {
    comptime {
        var list: []const Rule = &.{};
        for (rules.cel.items, 0..) |rule, index| {
            list = list ++ [_]Rule{.{ .field = "cel", .index = index, .id = rule.id orelse "", .message = rule.message orelse "", .expression = rule.expression orelse "" }};
        }
        // validate.proto, FieldRules.cel_expression: the expression is the rule's id.
        for (rules.cel_expression.items, 0..) |expression, index| {
            list = list ++ [_]Rule{.{ .field = "cel_expression", .index = index, .id = expression, .message = "", .expression = expression }};
        }
        return list;
    }
}

/// The CEL type of a whole repeated field or map `F`, which is `this` for the field's own CEL
/// rules. Null for a map the module does not read.
pub fn Whole(comptime F: type) ?type {
    if (!shape.is_map(F)) return list_file.List(F);
    return if (list_file.map_is_read(F)) list_file.Map(F) else null;
}

/// Checks a whole repeated field or map against its own CEL rules and against the predefined
/// rules of its rule message, `RepeatedRules` or `MapRules`.
pub fn check_whole(comptime F: type, comptime rules: pb.FieldRules, comptime predefined: []const table.Rules.Predefined, field: *const F, walk: *Walk, path: *const Path) Fault!void {
    if (comptime states(rules)) try check_field(rules, .{}, Whole(F).?{ .field = field }, walk, path);
    if (comptime predefined.len != 0) try check_predefined(rules, .{ .predefined = predefined }, Whole(F).?{ .field = field }, walk, path);
}

/// Whether `rules` state a CEL rule.
pub fn states(comptime rules: anytype) bool {
    return !rules.cel.is_empty() or !rules.cel_expression.is_empty();
}

/// What stops the CEL rules of `rules` from being checked for a `this` of type `This`, or null.
pub fn problem_of(comptime rules: anytype, comptime This: type) ?[]const u8 {
    comptime {
        const scope: Scope = .{ .types = &.{This} };
        for (rules_of(rules)) |rule| {
            if (program.problem_of(rule.expression, scope)) |problem| return problem;
            const R = program.Type(rule.expression, scope);
            // validate.proto, Rule.expression: "the expression must evaluate to either a
            // boolean or a string".
            if (R != bool and R != []const u8 and R != type_file.Failing) {
                return "`" ++ rule.expression ++ "`: a rule's expression gives a bool or a string, not a " ++ type_file.name_of(R);
            }
        }
        return null;
    }
}

/// The path of a field's rule within `buf.validate.FieldRules`: the site's prefix, then the
/// rule's field with its index.
fn path_of(comptime site: Site, comptime rule: Rule) pb.FieldPath {
    comptime {
        var element = table.rule_element(pb.FieldRules, rule.field);
        element.subscript = .{ .index = rule.index };
        return .{ .elements = .of(site.prefix ++ [_]table.Element{element}) };
    }
}

/// Checks a field's value, as the CEL value `this`, against the CEL rules of `rules`.
pub fn check_field(comptime rules: pb.FieldRules, comptime site: Site, this: anytype, walk: *Walk, path: *const Path) Fault!void {
    inline for (comptime rules_of(rules)) |rule| {
        if (try broken(rule, this, walk)) |message| {
            try walk_file.violate_text(walk, path, comptime path_of(site, rule), rule.id, message, site.for_key, comptime formats(rule));
        }
    }
}

/// Checks a message against the CEL rules of its `(buf.validate.message)` option. A violation
/// names the message's own field, and no rule path: the path is one of a field's rules.
pub fn check_message(comptime M: type, comptime rules: pb.MessageRules, message: *const M, walk: *Walk, path: ?*const Path) Fault!void {
    inline for (comptime rules_of(rules)) |rule| {
        if (try broken(rule, message, walk)) |text| try walk_file.violate_text(walk, path, null, rule.id, text, false, comptime formats(rule));
    }
}

/// Whether `rule`'s expression may call `format`, whose text the report's storage keeps. A
/// rule that names `format` in another way, as a field, only costs a copy of its message.
fn formats(comptime rule: Rule) bool {
    return std.mem.indexOf(u8, rule.expression, "format") != null;
}

/// The message of the violation when `this` breaks `rule`, or null.
fn broken(comptime rule: Rule, this: anytype, walk: *const Walk) Fault!?[]const u8 {
    return verdict(rule, comptime .{ .types = &.{@TypeOf(this)} }, .{this}, walk);
}

/// Runs a rule's expression for `values`, one for each name of `scope`, and gives the
/// violation's message when the result breaks the rule, or null.
fn verdict(comptime rule: Rule, comptime scope: Scope, values: anytype, walk: *const Walk) Fault!?[]const u8 {
    // An expression that `dyn` let through with a mistake of types fails each time it runs.
    if (comptime program.Type(rule.expression, scope) == type_file.Failing) return error.Unevaluable;
    // A rule that does not format holds no text at all, so it stores nothing for one.
    var text: if (formats(rule)) type_file.Text else void = if (comptime formats(rule)) .{ .room = report_file.room(walk.report), .full = &walk.report.truncated } else {};
    var env: type_file.Env = .{ .now = walk.options.now, .text = if (comptime formats(rule)) &text else null };
    const result = try program.run(rule.expression, scope, values, &env);
    if (comptime @TypeOf(result) == bool) {
        if (result) return null;
        // protovalidate's libraries state this text for a rule with no message.
        return comptime if (rule.message.len != 0) rule.message else "\"" ++ rule.expression ++ "\" returned false";
    }
    if (result.len == 0) return null;
    return result;
}

const Predefined = table.Rules.Predefined;

/// The CEL type of an extension's value, which an expression reads as `rule`: a scalar, or a
/// list of as many elements as the schema states.
fn RuleValue(comptime value: Predefined.Value) type {
    return switch (value) {
        .boolean => bool,
        .int => i64,
        .uint => u64,
        .double => f64,
        .string => []const u8,
        .bytes => type_file.Bytes,
        .booleans => |list| [list.len]bool,
        .ints => |list| [list.len]i64,
        .uints => |list| [list.len]u64,
        .doubles => |list| [list.len]f64,
        .strings => |list| [list.len][]const u8,
    };
}

fn rule_value(comptime value: Predefined.Value) RuleValue(value) {
    return switch (value) {
        .bytes => |octets| .{ .octets = octets },
        inline .booleans, .ints, .uints, .doubles, .strings => |list| list[0..list.len].*,
        inline else => |scalar| scalar,
    };
}

/// The rule message that a field's rules hold for the field's type, which an expression reads
/// as `rules`: its type, a pointer to it, and its member's name in `buf.validate.FieldRules`.
const Holder = struct { Message: type, message: *const anyopaque, member: []const u8 };

fn holder_of(comptime rules: pb.FieldRules) ?Holder {
    const typed = rules.type orelse return null;
    switch (typed) {
        inline else => |payload, tag| {
            const P = @TypeOf(payload);
            // `repeated` and `map` hold their rules behind a pointer, since each may hold
            // `FieldRules` again.
            if (shape.is_lazy(P)) return .{ .Message = P.Message, .message = payload.value.?, .member = @tagName(tag) };
            // A copy with a place of its own, which a pointer may name after this call.
            const Kept = struct {
                const instance: P = payload;
            };
            return .{ .Message = P, .message = &Kept.instance, .member = @tagName(tag) };
        },
    }
}

/// The names a predefined rule's expression reads: `this`, the extension's value as `rule`,
/// and the rule message that holds the extension as `rules` (validate.proto, PredefinedRules).
fn predefined_scope(comptime entry: Predefined, comptime holder: Holder, comptime This: type) Scope {
    return .{ .names = &.{ "this", "rule", "rules" }, .types = &.{ This, RuleValue(entry.value), *const holder.Message } };
}

fn predefined_rules(comptime entry: Predefined) []const Rule {
    comptime {
        var list: []const Rule = &.{};
        for (entry.cel, 0..) |rule, index| {
            list = list ++ [_]Rule{.{ .field = "", .index = index, .id = rule.id orelse "", .message = rule.message orelse "", .expression = rule.expression orelse "" }};
        }
        return list;
    }
}

/// What stops the predefined rules of `entries` from being checked for a `this` of type
/// `This`, under the field rules that hold their extensions, or null.
pub fn predefined_problem_of(comptime rules: pb.FieldRules, comptime entries: []const Predefined, comptime This: type) ?[]const u8 {
    comptime {
        if (entries.len == 0) return null;
        const holder = holder_of(rules) orelse return "a predefined rule's extension has no rule message to lie in";
        for (entries) |entry| {
            const scope = predefined_scope(entry, holder, This);
            for (predefined_rules(entry)) |rule| {
                if (program.problem_of(rule.expression, scope)) |problem| return "(" ++ entry.name ++ "): " ++ problem;
                const R = program.Type(rule.expression, scope);
                if (R != bool and R != []const u8 and R != type_file.Failing) {
                    return "(" ++ entry.name ++ "): `" ++ rule.expression ++ "`: a rule's expression gives a bool or a string, not a " ++ type_file.name_of(R);
                }
            }
        }
        return null;
    }
}

/// The path of a predefined rule: the site's prefix, the rule message's member, and the
/// extension, whose name a path states in brackets.
fn predefined_path(comptime site: Site, comptime holder: Holder, comptime entry: Predefined) pb.FieldPath {
    comptime {
        const extension: table.Element = .{ .field_number = @intCast(entry.number), .field_name = "[" ++ entry.name ++ "]", .field_type = entry.type };
        return .{ .elements = .of(site.prefix ++ [_]table.Element{ table.rule_element(pb.FieldRules, holder.member), extension }) };
    }
}

/// Checks a value, as the CEL value `this`, against the predefined rules of `site`.
pub fn check_predefined(comptime rules: pb.FieldRules, comptime site: Site, this: anytype, walk: *Walk, path: *const Path) Fault!void {
    const holder = comptime holder_of(rules).?;
    const held: *const holder.Message = comptime @ptrCast(@alignCast(holder.message));
    inline for (site.predefined) |entry| {
        const scope = comptime predefined_scope(entry, holder, @TypeOf(this));
        inline for (comptime predefined_rules(entry)) |rule| {
            if (try verdict(rule, scope, .{ this, comptime rule_value(entry.value), held }, walk)) |message| {
                try walk_file.violate_text(walk, path, comptime predefined_path(site, holder, entry), rule.id, message, site.for_key, comptime formats(rule));
            }
        }
    }
}
