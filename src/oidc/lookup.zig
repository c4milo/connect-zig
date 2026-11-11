//! The lookups of a program's own claims in a verified token's payload (RFC 7519 §4.2 and §4.3):
//! one member of the Claims Set, read when the program asks for it.
//!
//! `Verifier.verify` read the payload whole before it kept it: one JSON object, nested no deeper
//! than `constants.json_depth_max`. So a lookup's reader never refuses it, and only a token longer
//! than its storage reads as `.long`.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const Reader = @import("reader.zig").Reader;

pub const Error = error{
    /// The claim holds a value of another type than the lookup reads.
    WrongType,
    /// The claim's string is longer than `constants.claim_bytes_max`.
    ClaimTooLong,
};

const decimal_base = 10;

/// The string of the member `name`, in `storage`, or null when the payload holds no such member.
pub fn string(payload: []const u8, name: []const u8, storage: []u8) Error!?[]const u8 {
    var reader: Reader = undefined;
    if (!find(&reader, payload, name, storage)) return null;
    return switch (reader.next() catch unreachable) {
        .string => |octets| octets,
        .long => error.ClaimTooLong,
        else => error.WrongType,
    };
}

/// The integer of the member `name`, or null when the payload holds no such member. A number
/// with a fraction, with an exponent, or past an i64 is `error.WrongType`.
pub fn integer(payload: []const u8, name: []const u8, storage: []u8) Error!?i64 {
    var reader: Reader = undefined;
    if (!find(&reader, payload, name, storage)) return null;
    return switch (reader.next() catch unreachable) {
        .number => |digits| std.fmt.parseInt(i64, digits, decimal_base) catch error.WrongType,
        else => error.WrongType,
    };
}

/// Whether the member `name` is the string `value`, or an array that holds it. An array's other
/// values pass unread; a member of another type is `error.WrongType`.
pub fn holds(payload: []const u8, name: []const u8, value: []const u8, storage: []u8) Error!bool {
    // A value the storage cannot hold never compares equal, so the program asks for none.
    assert(value.len <= storage.len);
    var reader: Reader = undefined;
    if (!find(&reader, payload, name, storage)) return false;
    switch (reader.next() catch unreachable) {
        .string => |octets| return std.mem.eql(u8, octets, value),
        // A string longer than the storage, which `value` is not.
        .long => return false,
        .begin_array => {},
        else => return error.WrongType,
    }
    var found = false;
    // Bounded: each value takes at least one octet of the payload.
    for (0..payload.len + 1) |_| {
        switch (reader.next() catch unreachable) {
            .end_array => return found,
            .string => |octets| found = found or std.mem.eql(u8, octets, value),
            .begin_object, .begin_array => reader.skip_container() catch unreachable,
            .number, .literal, .long => {},
            // The decoder returns a value or the array's end here (RFC 8259 §5).
            .end_object, .name, .end => unreachable,
        }
    }
    unreachable;
}

/// Moves `reader` to the value of the last member named `name`, or returns false when the
/// payload holds none. RFC 7519 §4: a parser that takes a name twice returns the lexically last
/// member. `verify` refuses a second "iss", "sub", "aud", "exp" or "nbf".
fn find(reader: *Reader, payload: []const u8, name: []const u8, storage: []u8) bool {
    // A name the storage cannot hold reads as `.long`, and never compares equal.
    assert(name.len <= storage.len);
    // A `Claims` that no `verify` filled holds no payload.
    if (payload.len == 0) return false;
    const count = count_of(reader, payload, name, storage);
    if (count == 0) return false;
    reader.init(payload, storage);
    reader.expect(.begin_object) catch unreachable;
    var seen: usize = 0;
    // Bounded: each member takes at least one octet of the payload.
    for (0..payload.len + 1) |_| {
        if (next_member(reader, name).?) {
            seen += 1;
            if (seen == count) return true;
            reader.skip_value() catch unreachable;
        }
    }
    unreachable;
}

/// The members named `name` in the payload.
fn count_of(reader: *Reader, payload: []const u8, name: []const u8, storage: []u8) usize {
    reader.init(payload, storage);
    reader.expect(.begin_object) catch unreachable;
    var count: usize = 0;
    // Bounded: each member takes at least one octet of the payload.
    for (0..payload.len + 1) |_| {
        const named = next_member(reader, name) orelse return count;
        if (named) {
            count += 1;
            reader.skip_value() catch unreachable;
        }
    }
    unreachable;
}

/// Reads the next member's name: true when it is `name`, with the reader at its value; false
/// after the reader passed over its value; null at the object's end.
fn next_member(reader: *Reader, name: []const u8) ?bool {
    switch (reader.next() catch unreachable) {
        .end_object => return null,
        .name => |octets| if (std.mem.eql(u8, octets, name)) return true,
        .long => {},
        // The decoder returns a name or the object's end here (RFC 8259 §4).
        .begin_object, .begin_array, .end_array, .string, .number, .literal, .end => unreachable,
    }
    reader.skip_value() catch unreachable;
    return false;
}

comptime {
    assert(constants.claim_bytes_max >= constants.reader_storage_bytes_min);
}
