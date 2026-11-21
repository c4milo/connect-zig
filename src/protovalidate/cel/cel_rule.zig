//! The CEL rules of a message and of a field: `cel` and `cel_expression` (validate.proto, Rule,
//! MessageRules and FieldRules). Each rule's expression gives a bool, where false breaks the
//! rule, or a string, where a string that is not empty breaks it and is the violation's
//! message.
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("../table.zig");
const walk_file = @import("../walk.zig");
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
            try walk_file.violate_text(walk, path, comptime path_of(site, rule), rule.id, message, site.for_key);
        }
    }
}

/// Checks a message against the CEL rules of its `(buf.validate.message)` option. A violation
/// names the message's own field, and no rule path: the path is one of a field's rules.
pub fn check_message(comptime M: type, comptime rules: pb.MessageRules, message: *const M, walk: *Walk, path: ?*const Path) Fault!void {
    inline for (comptime rules_of(rules)) |rule| {
        if (try broken(rule, message, walk)) |text| try walk_file.violate_text(walk, path, null, rule.id, text, false);
    }
}

/// The message of the violation when `this` breaks `rule`, or null.
fn broken(comptime rule: Rule, this: anytype, walk: *const Walk) Fault!?[]const u8 {
    const scope: Scope = comptime .{ .types = &.{@TypeOf(this)} };
    // An expression that `dyn` let through with a mistake of types fails each time it runs.
    if (comptime program.Type(rule.expression, scope) == type_file.Failing) return error.Unevaluable;
    var env: type_file.Env = .{ .now = walk.options.now };
    const result = try program.run(rule.expression, scope, .{this}, &env);
    if (comptime @TypeOf(result) == bool) {
        if (result) return null;
        // protovalidate's libraries state this text for a rule with no message.
        return comptime if (rule.message.len != 0) rule.message else "\"" ++ rule.expression ++ "\" returned false";
    }
    if (result.len == 0) return null;
    return result;
}
