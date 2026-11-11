//! The JSON tokens of a text whose octets are all in one buffer, for a token's header, its claims
//! and a JWK Set. It is stdx's streaming decoder with one difference from `json.TextReader`: a
//! name, a string or a number longer than the storage is the item `long`, not an error. A JWK
//! Set may hold a certificate chain ("x5c", RFC 7517 §4.7) that no storage here has room for, and
//! the verifier reads nothing from it.
const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const codec = @import("codec");
const constants = @import("constants.zig");

pub const Error = error{Malformed};

pub const Reader = struct {
    decoder: json.Decoder,
    input: []const u8,
    consumed: usize,
    storage: []u8,

    /// A token. A name's, a string's or a number's octets lie in the reader's storage until the
    /// next call.
    pub const Item = union(enum) {
        begin_object,
        end_object,
        begin_array,
        end_array,
        name: []const u8,
        string: []const u8,
        number: []const u8,
        /// `true`, `false` or `null`.
        literal,
        /// A name, a string or a number longer than the storage.
        long,
        /// The text's end.
        end,
    };

    pub fn init(reader: *Reader, input: []const u8, storage: []u8) void {
        assert(storage.len >= constants.reader_storage_bytes_min);
        reader.* = .{ .decoder = undefined, .input = input, .consumed = 0, .storage = storage };
        reader.decoder.init(.text, codec.Features.target());
    }

    /// The next token. A text that is not JSON (RFC 8259), one that ends early among them, is
    /// `error.Malformed`.
    pub fn next(reader: *Reader) Error!Item {
        var long = false;
        // Bounded: each call that fills the storage takes input, and each other call returns.
        for (0..reader.input.len + 1) |_| {
            const progress = reader.decoder.decode(reader.input[reader.consumed..], reader.storage, .last) catch return error.Malformed;
            reader.consumed += progress.consumed;
            switch (progress.status) {
                .token => return if (long) .long else item(progress.kind.?, reader.storage[0..progress.written]),
                .done => return .end,
                // The whole text is here, so a token that needs more input never ends.
                .needs_input => return error.Malformed,
                // The storage is full inside a token: the next call writes over it.
                .needs_room => long = true,
            }
        }
        unreachable;
    }

    /// Takes the token `expected`, which carries no octets.
    pub fn expect(reader: *Reader, expected: std.meta.Tag(Item)) Error!void {
        if (try reader.next() != expected) return error.Malformed;
    }

    /// A string's octets, or `error.Malformed` for another token or a string longer than the
    /// storage.
    pub fn string(reader: *Reader) Error![]const u8 {
        return switch (try reader.next()) {
            .string => |octets| octets,
            else => error.Malformed,
        };
    }

    /// The string that is the next value, or null after the reader passed over a value of another
    /// kind, or a string longer than the storage.
    pub fn string_or_skip(reader: *Reader) Error!?[]const u8 {
        switch (try reader.next()) {
            .string => |octets| return octets,
            .number, .literal, .long => return null,
            .begin_object, .begin_array => {
                try reader.skip_container();
                return null;
            },
            .end_object, .end_array, .name, .end => return error.Malformed,
        }
    }

    /// Passes over the value whose first token is next.
    pub fn skip_value(reader: *Reader) Error!void {
        switch (try reader.next()) {
            .begin_object, .begin_array => return reader.skip_container(),
            .name, .string, .number, .literal, .long => {},
            // A container's end, or the text's, where a value starts is no value.
            .end_object, .end_array, .end => return error.Malformed,
        }
    }

    /// Passes over the rest of the container whose start the reader took, nested at most
    /// `json_depth_max` with it.
    pub fn skip_container(reader: *Reader) Error!void {
        var depth: u32 = 1;
        // Bounded: each token takes at least one octet of the input.
        for (0..reader.input.len + 1) |_| {
            switch (try reader.next()) {
                .begin_object, .begin_array => {
                    depth += 1;
                    if (depth > constants.json_depth_max) return error.Malformed;
                },
                .end_object, .end_array => {
                    depth -= 1;
                    if (depth == 0) return;
                },
                .name, .string, .number, .literal, .long => {},
                // The decoder ends a text only after each container closed (RFC 8259 §2).
                .end => unreachable,
            }
        }
        unreachable;
    }
};

/// The members of one object that a caller reads, by name: `Name` is an enum whose fields spell
/// them. `next` passes over each other member. A member the caller reads appears once: RFC 7515
/// §4, RFC 7517 §4 and RFC 7519 §4 let a parser refuse a name that appears twice, and the
/// verifier does, so no two parsers read two values from one text.
pub fn Members(comptime Name: type) type {
    return struct {
        reader: *Reader,
        seen: std.EnumSet(Name) = .initEmpty(),

        /// The next member the caller reads, with the reader at its value, or null at the
        /// object's end.
        pub fn next(members: *@This()) Error!?Name {
            const reader = members.reader;
            // Bounded: each member takes at least one octet of the input.
            for (0..reader.input.len + 1) |_| {
                switch (try reader.next()) {
                    .end_object => return null,
                    .name => |octets| if (std.meta.stringToEnum(Name, octets)) |name| {
                        if (members.seen.contains(name)) return error.Malformed;
                        members.seen.insert(name);
                        return name;
                    },
                    .long => {},
                    // The decoder returns a name or the object's end here (RFC 8259 §4).
                    .begin_object, .begin_array, .end_array, .string, .number, .literal, .end => unreachable,
                }
                try reader.skip_value();
            }
            unreachable;
        }
    };
}

fn item(kind: json.Kind, octets: []const u8) Reader.Item {
    return switch (kind) {
        .begin_object => .begin_object,
        .end_object => .end_object,
        .begin_array => .begin_array,
        .end_array => .end_array,
        .name => .{ .name = octets },
        .string => .{ .string = octets },
        .number => .{ .number = octets },
        .true, .false, .null => .literal,
    };
}

const testing = std.testing;

test "the reader returns each token, and a string longer than its storage as long" {
    var storage: [8]u8 = undefined;
    var reader: Reader = undefined;
    reader.init("{\"a\":\"0123456789abcdef\",\"b\":[true,12],\"c\":\"\\u00e9\"}", &storage);
    try reader.expect(.begin_object);
    try testing.expectEqualStrings("a", (try reader.next()).name);
    try testing.expectEqual(Reader.Item.long, try reader.next());
    try testing.expectEqualStrings("b", (try reader.next()).name);
    try reader.expect(.begin_array);
    try reader.expect(.literal);
    try testing.expectEqualStrings("12", (try reader.next()).number);
    try reader.expect(.end_array);
    try testing.expectEqualStrings("c", (try reader.next()).name);
    try testing.expectEqualStrings("\u{e9}", try reader.string());
    try reader.expect(.end_object);
    try reader.expect(.end);
}

test "the reader refuses a text that is not JSON, and one that ends early" {
    var storage: [8]u8 = undefined;
    for ([_][]const u8{ "", "{", "{\"a\"", "{\"a\":\"b", "nul", "{'a':1}", "{\"a\":1}}" }) |text| {
        var reader: Reader = undefined;
        reader.init(text, &storage);
        var failed = false;
        for (0..text.len + 2) |_| {
            const token = reader.next() catch {
                failed = true;
                break;
            };
            if (token == .end) break;
        }
        try testing.expect(failed);
    }
}

test "skip_value passes over one value, and refuses one nested too deep" {
    var storage: [8]u8 = undefined;
    var reader: Reader = undefined;
    reader.init("[{\"a\":[1,{\"b\":null}],\"c\":\"0123456789\"},7]", &storage);
    try reader.expect(.begin_array);
    try reader.skip_value();
    try testing.expectEqualStrings("7", (try reader.next()).number);
    try reader.expect(.end_array);

    const deep = "[" ** (constants.json_depth_max + 1) ++ "]" ** (constants.json_depth_max + 1);
    reader.init(deep, &storage);
    try testing.expectError(error.Malformed, reader.skip_value());
    reader.init(deep[1 .. deep.len - 1], &storage);
    try reader.skip_value();
    try reader.expect(.end);

    // A container's end where a value starts is no value.
    reader.init("[]", &storage);
    try reader.expect(.begin_array);
    try testing.expectError(error.Malformed, reader.skip_value());
}

test "string_or_skip returns a string, and passes over a value of another kind" {
    var storage: [8]u8 = undefined;
    var reader: Reader = undefined;
    reader.init("[\"ab\",1,null,{\"a\":[2]},[3],\"0123456789\",\"cd\"]", &storage);
    try reader.expect(.begin_array);
    try testing.expectEqualStrings("ab", (try reader.string_or_skip()).?);
    for (0..5) |_| try testing.expectEqual(@as(?[]const u8, null), try reader.string_or_skip());
    try testing.expectEqualStrings("cd", (try reader.string_or_skip()).?);
    try testing.expectError(error.Malformed, reader.string_or_skip());
}

test "Members returns the members a caller reads, once each, and passes over the others" {
    const Name = enum { alg, kid };
    var storage: [8]u8 = undefined;
    var reader: Reader = undefined;
    reader.init("{\"x\":{\"alg\":1},\"kid\":\"k\",\"a-name-past-the-storage\":[1],\"alg\":\"a\",\"y\":2}", &storage);
    try reader.expect(.begin_object);
    var members: Members(Name) = .{ .reader = &reader };
    try testing.expectEqual(Name.kid, (try members.next()).?);
    try testing.expectEqualStrings("k", try reader.string());
    try testing.expectEqual(Name.alg, (try members.next()).?);
    try testing.expectEqualStrings("a", try reader.string());
    try testing.expectEqual(@as(?Name, null), try members.next());
    try reader.expect(.end);

    // RFC 7515 §4: a name that appears twice is refused.
    reader.init("{\"kid\":\"a\",\"kid\":\"b\"}", &storage);
    try reader.expect(.begin_object);
    var twice: Members(Name) = .{ .reader = &reader };
    try testing.expectEqual(Name.kid, (try twice.next()).?);
    try reader.skip_value();
    try testing.expectError(error.Malformed, twice.next());
}
