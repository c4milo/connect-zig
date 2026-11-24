//! Example: generated messages through the binary encoding and proto3 JSON, with no RPC at all.
//!
//! The program builds a `kitchen.v1.Tree` from the code that `buf generate` wrote into gen/. A
//! `Tree` has a nested message, a map, a oneof, a recursive field and well-known types. The
//! program encodes it to binary and decodes it back, then writes it as JSON and reads that back.
//! `decode` copies no string: each string of a decoded message points into the bytes that the
//! program decoded, which the program keeps. `decode_into` reads the elements of each repeated
//! field into storage that the program passes, so a read of them parses nothing again (decision
//! 37).
//!
//! Every buffer is the program's, in one `State` that `main` allocates (decision 42). The library
//! allocates nothing. So a buffer that is too small is an error the program sees, not an
//! allocation that it cannot see.
//!
//! The program checks every value that it reads back, and exits with an error otherwise. That is
//! how `zig build test` and CI know that the example works. Run it with `zig build run`.
const std = @import("std");
const proto = @import("connect_zig").protobuf;
const kitchen = @import("kitchen");
const constants = @import("constants.zig");

pub const Error = error{ExampleWrong};

/// All the program holds, which `main` allocates once (decision 42). `binary` holds the encoded
/// message and `text` its JSON text. A JSON read writes the binary form into `from_json`, and
/// reads one token at a time into `tokens`. `decode_into` reads the elements of repeated fields
/// into `storage`.
const State = struct {
    binary: [constants.message_len]u8,
    text: [constants.message_len]u8,
    from_json: [constants.message_len]u8,
    tokens: [constants.token_len]u8,
    storage: [constants.storage_len]u8 align(constants.storage_align),
};

/// The values the program writes, and checks when it reads them back.
const label_key: i32 = 7;
const sint64_value: i64 = -9;
const created_seconds = 1_700_000_000;
const created_nanos = 5_000_000;

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    // The program detects the CPU's features once, as it starts, and decodes and encodes with
    // them from then on. Binary `encode` uses none.
    const decoder: proto.Decoder = .init(.detect());
    const encoder: proto.Encoder = .init(decoder.cpu_features);
    // A recursive field is a `proto.Lazy`. It holds a pointer to encode, and bytes once decoded.
    const parent: kitchen.Tree = .{ .name = "root" };
    const tree: kitchen.Tree = .{
        .name = "leaf",
        .parent = .of(&parent),
        // A repeated field and a map take a slice to encode. A map is a list of its entries.
        .children = .of(&.{.{ .name = "child" }}),
        .labels = .of(&.{.{ .key = label_key, .value = "seven" }}),
        // A oneof is an optional union. A message inside it needs no presence of its own.
        .payload = .{ .scalars = .{ .a_sint64 = sint64_value, .maybe = 0, .mood = .mood_happy } },
        .created = .{ .seconds = created_seconds, .nanos = created_nanos },
        .nickname = .{ .value = "sprout" },
    };

    // Binary: `encode` writes into the program's buffer and returns the bytes it wrote.
    const bytes = try proto.encode(kitchen.Tree, &tree, &state.binary);
    // `decode_into` reads the elements of each repeated field into `storage` once, for a program
    // that reads every field. `decode` leaves them in `bytes`, and each read parses them again.
    const decoded = try decoder.decode_into(kitchen.Tree, bytes, &state.storage);
    std.debug.print("binary: {d} bytes, name \"{s}\"\n", .{ bytes.len, decoded.name });
    try check_tree(&decoded);

    // JSON: field names in lowerCamelCase, 64-bit integers as strings, a Timestamp as RFC 3339.
    const json = try encoder.encode_json(kitchen.Tree, &decoded, &state.text);
    std.debug.print("json: {s}\n", .{json});
    // A JSON read writes the binary form into `from_json`, and the strings then point into it.
    const read = try decoder.decode_json(kitchen.Tree, json, &state.from_json, &state.tokens);
    try check_tree(&read);
    std.debug.print("protobuf_messages: every value read back as written\n", .{});
}

fn check_tree(tree: *const kitchen.Tree) !void {
    const parent = try tree.parent.get() orelse return error.ExampleWrong;
    if (!std.mem.eql(u8, parent.name, "root")) return error.ExampleWrong;
    // `map_get` reads the entries of a map, and returns the value of the last entry with the key.
    const label = try proto.map_get(@TypeOf(tree.labels), &tree.labels, label_key) orelse return error.ExampleWrong;
    if (!std.mem.eql(u8, label, "seven")) return error.ExampleWrong;
    // The program reads a repeated field through its iterator, from storage or from the bytes.
    // The iterator gives a message in place, as a pointer, and a number or a string by value.
    var children = tree.children.iterator();
    const child = try children.next() orelse return error.ExampleWrong;
    if (!std.mem.eql(u8, child.name, "child")) return error.ExampleWrong;
    const scalars = tree.payload.?.scalars;
    // `maybe` has explicit presence, so its zero stays, where the zero of an implicit field would not.
    if (scalars.a_sint64 != sint64_value or scalars.maybe != 0 or scalars.mood != .mood_happy) return error.ExampleWrong;
    if (tree.created.?.nanos != created_nanos or !std.mem.eql(u8, tree.nickname.?.value, "sprout")) return error.ExampleWrong;
}
