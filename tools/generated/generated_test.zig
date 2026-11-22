//! The code `buf generate` wrote into examples/gen compiles, and its messages round-trip through
//! the binary encoding and proto3 JSON (design §8 step 6).
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const kitchen = @import("kitchen");
const eliza = @import("eliza");
const large = @import("large");
const protovalidate = @import("protovalidate");
const wide = @import("wide");

test "every generated declaration compiles" {
    testing.refAllDecls(kitchen);
    testing.refAllDecls(eliza);
    testing.refAllDecls(large);
    try testing.expectEqualStrings("/connectrpc.eliza.v1.ElizaService/Say", comptime eliza.ElizaService.say.path());
    try testing.expectEqual(.bidi_stream, eliza.ElizaService.converse.stream_type);
}

test "a generated message with every shape round-trips through binary and JSON" {
    const parent: kitchen.Tree = .{ .name = "root" };
    const tree: kitchen.Tree = .{
        .name = "leaf",
        .parent = .of(&parent),
        .children = .of(&.{.{ .name = "child" }}),
        .labels = .of(&.{.{ .key = 7, .value = "seven" }}),
        .payload = .{ .scalars = .{ .a_sint64 = -9, .maybe = 0, .mood = .mood_sad, .unpacked_numbers = .of(&.{ 1, 2 }) } },
        .leaves = .of(&.{.{ .kind = .kind_green, .tag = .{ .value = "t" } }}),
        .created = .{ .seconds = 1, .nanos = 5 },
        .nickname = .{ .value = "n" },
        .type = "kind",
    };
    var binary: [1024]u8 = undefined;
    const bytes = try proto.encode(kitchen.Tree, &tree, &binary);
    const back = try proto.decode(kitchen.Tree, bytes);
    try testing.expectEqualStrings("root", (try back.parent.get()).?.name);
    try testing.expectEqual(@as(i64, -9), back.payload.?.scalars.a_sint64);
    try testing.expectEqualStrings("seven", (try proto.map_get(@TypeOf(back.labels), &back.labels, @as(i32, 7))).?);
    var text: [1024]u8 = undefined;
    const json = try proto.encode_json(kitchen.Tree, &back, &text);
    var scratch: [2048]u8 = undefined;
    var tokens: [256]u8 = undefined;
    const from_json = try proto.decode_json(kitchen.Tree, json, &scratch, &tokens);
    try testing.expectEqual(kitchen.Mood.mood_sad, from_json.payload.?.scalars.mood);
    var leaves = from_json.leaves.iterator();
    try testing.expectEqualStrings("t", (try leaves.next()).?.tag.?.value);
    try testing.expectEqualStrings("kind", from_json.type);
}

test "a split file's pieces name each other, and round-trip as one file would" {
    const owner: large.Account = .{ .field_80 = 80, .profile = .{ .display_name = "Ada", .visibility = .visibility_public }, .tag = .{ .value = "t" } };
    const ledger: large.Ledger = .{ .field_1 = -1, .owner = owner, .visibility = .visibility_public, .children = .of(&.{.{ .field_2 = 2 }}) };
    var binary: [1024]u8 = undefined;
    const back = try proto.decode(large.Ledger, try proto.encode(large.Ledger, &ledger, &binary));
    try testing.expectEqualStrings("Ada", back.owner.?.profile.?.display_name);
    try testing.expectEqual(large.Account.Profile.Visibility.visibility_public, back.visibility);
    try testing.expectEqualStrings("t", back.owner.?.tag.?.value);
    try testing.expectEqual(@as(i64, 80), back.owner.?.field_80);
    try testing.expectEqual(.unary, large.LedgerService.get_ledger.stream_type);
    try testing.expectEqual(@as(u32, 81), large.Ledger.protobuf.fields[80].number);
}

/// The values the wide message's tests set, each past the rule of its field.
const past_expression = 2000;
const past_items_limit = 100;
/// The octets the wide message's tests encode into: a few fields are set.
const wide_room = 4096;

test "a message of 1,200 fields round-trips through binary and JSON" {
    const leaf: wide.Leaf = .{ .name = "end" };
    const message: wide.Wide = .{ .f1 = 1, .f2 = "ab", .f299 = .of(&.{ 1, 0 }), .f597 = 1, .f598 = "last text", .f600 = leaf };
    var binary: [wide_room]u8 = undefined;
    const bytes = try proto.encode(wide.Wide, &message, &binary);
    try testing.expectEqual(bytes.len, try proto.encoded_len(wide.Wide, &message));
    const back = try proto.decode(wide.Wide, bytes);
    try testing.expectEqual(@as(i32, 1), back.f1);
    try testing.expectEqualStrings("last text", back.f598);
    try testing.expectEqualStrings("end", back.f600.?.name);
    var text: [wide_room]u8 = undefined;
    const json = try proto.encode_json(wide.Wide, &back, &text);
    try testing.expectEqualStrings("{\"f1\":1,\"f2\":\"ab\",\"f299\":[1,0],\"f597\":1,\"f598\":\"last text\",\"f600\":{\"name\":\"end\"}}", json);
    var scratch: [wide_room]u8 = undefined;
    var tokens: [wide_room]u8 = undefined;
    const again = try proto.decode_json(wide.Wide, json, &scratch, &tokens);
    try testing.expectEqual(@as(i32, 1), again.f597);
    var elements = again.f299.iterator();
    try testing.expectEqual(@as(?i32, 1), try elements.next());
}

test "a message of 1,200 fields is checked against the rules of each field" {
    try testing.expect(comptime protovalidate.rules_error(wide.Wide) == null);
    var storage: [protovalidate.constants.report_bytes_default]u8 align(@alignOf(protovalidate.Violation)) = undefined;
    var report: protovalidate.Report = .init(&storage);
    const leaf: wide.Leaf = .{ .name = "end" };
    const valid: wide.Wide = .{ .f1 = 1, .f2 = "ab", .f299 = .of(&.{ 1, 0 }), .f597 = 1, .f598 = "last text", .f600 = leaf };
    try protovalidate.validate(wide.Wide, &valid, .{}, &report);
    try testing.expectEqual(@as(usize, 0), report.violations().len);

    // The first field breaks its expression and the message's, and the last three fields break
    // their rules: a string that is refused, an element past its limit, and an empty name.
    const invalid: wide.Wide = .{ .f1 = past_expression, .f598 = "x", .f599 = .of(&.{past_items_limit}), .f600 = .{} };
    try testing.expectError(error.Invalid, protovalidate.validate(wide.Wide, &invalid, .{}, &report));
    const expected = [_][]const u8{ "wide.ends", "this < 1001", "string.not_in", "int32.lt", "string.min_len" };
    try testing.expectEqual(expected.len, report.violations().len);
    for (expected) |id| {
        var found = false;
        for (report.violations()) |violation| {
            if (std.mem.eql(u8, violation.rule_id.?, id)) found = true;
        }
        try testing.expect(found);
    }
}

/// The `max_items` of the rule of `Lists.f1`, and a list of one item more.
const lists_max_items = 4;
const past_max_items = [_]i32{0} ** (lists_max_items + 1);

test "a message of 1,100 repeated and map fields round-trips and is checked against its rules" {
    const leaf: wide.Leaf = .{ .name = "end" };
    const message: wide.Lists = .{ .f1 = .of(&.{ 1, 2 }), .f1098 = .of(&.{"last"}), .f1099 = .of(&.{leaf}), .f1100 = .of(&.{.{ .key = "k", .value = 7 }}) };
    var binary: [wide_room]u8 = undefined;
    const bytes = try proto.encode(wide.Lists, &message, &binary);
    const back = try proto.decode(wide.Lists, bytes);
    try testing.expectEqual(@as(?i32, 7), try proto.map_get(@TypeOf(back.f1100), &back.f1100, "k"));
    var text: [wide_room]u8 = undefined;
    const json = try proto.encode_json(wide.Lists, &back, &text);
    try testing.expectEqualStrings("{\"f1\":[1,2],\"f1098\":[\"last\"],\"f1099\":[{\"name\":\"end\"}],\"f1100\":{\"k\":7}}", json);

    try testing.expect(comptime protovalidate.rules_error(wide.Lists) == null);
    var storage: [protovalidate.constants.report_bytes_default]u8 align(@alignOf(protovalidate.Violation)) = undefined;
    var report: protovalidate.Report = .init(&storage);
    try protovalidate.validate(wide.Lists, &back, .{}, &report);
    // The first list has more items than its rule takes, and the last list's message breaks its own.
    const invalid: wide.Lists = .{ .f1 = .of(&past_max_items), .f1099 = .of(&.{.{}}) };
    try testing.expectError(error.Invalid, protovalidate.validate(wide.Lists, &invalid, .{}, &report));
    try testing.expectEqual(@as(usize, 2), report.violations().len);
    try testing.expectEqualStrings("repeated.max_items", report.violations()[0].rule_id.?);
    try testing.expectEqualStrings("string.min_len", report.violations()[1].rule_id.?);
}
