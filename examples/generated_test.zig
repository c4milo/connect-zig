//! The code `buf generate` wrote into examples/gen compiles, and its messages round-trip through
//! the binary encoding and proto3 JSON (design §8 step 6).
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const kitchen = @import("gen/kitchen/v1/kitchen.pb.zig");
const eliza = @import("gen/connectrpc/eliza/v1/eliza.pb.zig");
const large = @import("gen/large/v1/large.pb.zig");

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
