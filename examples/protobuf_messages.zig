//! Example: generated messages through the binary encoding and proto3 JSON, with no RPC at all.
//!
//! The program builds a `kitchen.v1.Tree`, a message with a nested message, a map, a oneof, a
//! recursive field and well-known types, from the code `buf generate` wrote into examples/gen. It
//! encodes it to binary and decodes it back, then writes it as JSON and reads that back. Decoding
//! copies no string: every string of a decoded message points into the bytes it was decoded
//! from, which the program keeps. `decode_into` reads each repeated field's elements into
//! storage the program passes, so reading them parses nothing again (decision 37).
//!
//! Every buffer is the program's. The library allocates nothing, so a buffer too small is an
//! error the program sees, not an allocation it cannot see.
//!
//! The program checks every value it reads back, and exits with an error otherwise, which is how
//! `zig build examples` and CI know the example works. Run it with `zig build
//! example-protobuf_messages`.
const std = @import("std");
const proto = @import("protobuf");
const kitchen = @import("kitchen");

pub const Error = error{ExampleWrong};

/// Room for the encoded message, its JSON text, and what reading JSON needs: the binary form it
/// writes, and one token at a time. `decode_into` reads the elements of repeated fields into
/// `storage`.
const message_len = 1024;
const token_len = 256;
const storage_len = 4096;

var binary: [message_len]u8 = undefined;
var text: [message_len]u8 = undefined;
var from_json: [message_len]u8 = undefined;
var tokens: [token_len]u8 = undefined;
var storage: [storage_len]u8 align(16) = undefined;

pub fn main() !void {
    // A recursive field is a `proto.Lazy`, which holds a pointer to encode and bytes once decoded.
    const parent: kitchen.Tree = .{ .name = "root" };
    const tree: kitchen.Tree = .{
        .name = "leaf",
        .parent = .of(&parent),
        // A repeated field and a map take a slice to encode; a map is a list of its entries.
        .children = .of(&.{.{ .name = "child" }}),
        .labels = .of(&.{.{ .key = 7, .value = "seven" }}),
        // A oneof is an optional union, and a message inside it needs no presence of its own.
        .payload = .{ .scalars = .{ .a_sint64 = -9, .maybe = 0, .mood = .mood_happy } },
        .created = .{ .seconds = 1_700_000_000, .nanos = 5_000_000 },
        .nickname = .{ .value = "sprout" },
    };

    // Binary: `encode` writes into the program's buffer and returns the bytes it wrote.
    const bytes = try proto.encode(kitchen.Tree, &tree, &binary);
    // `decode_into` reads each repeated field's elements into `storage` once, for a program
    // that reads every field. `decode` leaves them in `bytes`, and each read parses them again.
    const decoded = try proto.decode_into(kitchen.Tree, bytes, &storage);
    std.debug.print("binary: {d} bytes, name \"{s}\"\n", .{ bytes.len, decoded.name });
    try check_tree(&decoded);

    // JSON: field names in lowerCamelCase, 64-bit integers as strings, a Timestamp as RFC 3339.
    const json = try proto.encode_json(kitchen.Tree, &decoded, &text);
    std.debug.print("json: {s}\n", .{json});
    // Reading JSON writes the binary form into `from_json`, which the strings then point into.
    const read = try proto.decode_json(kitchen.Tree, json, &from_json, &tokens);
    try check_tree(&read);
    std.debug.print("protobuf_messages: every value read back as written\n", .{});
}

fn check_tree(tree: *const kitchen.Tree) !void {
    const parent = try tree.parent.get() orelse return error.ExampleWrong;
    if (!std.mem.eql(u8, parent.name, "root")) return error.ExampleWrong;
    // `map_get` reads a map's entries and returns the value of the last entry with the key.
    const label = try proto.map_get(@TypeOf(tree.labels), &tree.labels, @as(i32, 7)) orelse return error.ExampleWrong;
    if (!std.mem.eql(u8, label, "seven")) return error.ExampleWrong;
    // A repeated field is read through its iterator, from storage or from the bytes.
    var children = tree.children.iterator();
    const child = try children.next() orelse return error.ExampleWrong;
    if (!std.mem.eql(u8, child.name, "child")) return error.ExampleWrong;
    const scalars = tree.payload.?.scalars;
    // `maybe` has explicit presence, so its zero is kept, where an implicit field's would not be.
    if (scalars.a_sint64 != -9 or scalars.maybe != 0 or scalars.mood != .mood_happy) return error.ExampleWrong;
    if (tree.created.?.nanos != 5_000_000 or !std.mem.eql(u8, tree.nickname.?.value, "sprout")) return error.ExampleWrong;
}
