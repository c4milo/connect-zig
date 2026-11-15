//! One benchmark message and the operations timed on it. `prepare` encodes the message once in
//! binary and in JSON, and checks that both decode back to what was encoded, as the walk sees it.
const std = @import("std");
const assert = std.debug.assert;
const proto = @import("protobuf");
const constants = @import("constants.zig");

const buffer_len = constants.buffer_len;
const buffer_align = constants.buffer_align;

pub const Operation = enum {
    binary_encode,
    binary_decode,
    binary_decode_walk,
    json_encode,
    json_decode,
    json_decode_walk,

    /// The name the table prints, which bench/go prints too.
    pub fn label(operation: Operation) []const u8 {
        return switch (operation) {
            .binary_encode => "binary encode",
            .binary_decode => "binary decode",
            .binary_decode_walk => "binary decode+walk",
            .json_encode => "JSON encode",
            .json_decode => "JSON decode",
            .json_decode_walk => "JSON decode+walk",
        };
    }

    /// Whether the operation reads or writes JSON, whose length the table reports.
    pub fn is_json(operation: Operation) bool {
        return switch (operation) {
            .binary_encode, .binary_decode, .binary_decode_walk => false,
            .json_encode, .json_decode, .json_decode_walk => true,
        };
    }
};

/// The memory every operation reads and writes. `main` allocates it once, in its `State`
/// (decision 42), and hands it to each case.
pub const Buffers = struct {
    /// The canonical encodings, which every decode reads; and the output of each encode, which
    /// it overwrites. A decoded message points into the input it read, which stays here.
    binary_storage: [buffer_len]u8 align(buffer_align),
    json_storage: [buffer_len]u8 align(buffer_align),
    encode_scratch: [buffer_len]u8 align(buffer_align),
    json_scratch: [buffer_len]u8 align(buffer_align),
    transcoded: [buffer_len]u8 align(buffer_align),
    tokens: [constants.token_len]u8 align(buffer_align),
    /// The storage `decode_into` reads repeated fields into before a binary walk, as a program
    /// that reads every field takes it (decision 37). A decode alone takes `decode`, with none.
    storage: [constants.storage_len]u8 align(buffer_align),
};

pub fn Case(comptime T: type, comptime walk: fn (*const T) proto.Error!u64) type {
    return struct {
        const Self = @This();
        pub const Message = T;
        pub const walk_message = walk;

        input: *const T,
        buffers: *Buffers,
        binary: []const u8,
        json: []const u8,
        /// What the walk folds the input into, which every decode must give back.
        sum: u64,

        pub fn prepare(input: *const T, buffers: *Buffers) !Self {
            const binary = try proto.encode(T, input, &buffers.binary_storage);
            assert(binary.len == try proto.encoded_len(T, input));
            const case: Self = .{
                .input = input,
                .buffers = buffers,
                .binary = binary,
                .json = try proto.encode_json(T, input, &buffers.json_storage),
                .sum = try walk(input),
            };
            try check(Self, &case);
            return case;
        }

        /// The bytes one operation reads or writes.
        pub fn bytes(case: *const Self, operation: Operation) usize {
            return if (operation.is_json()) case.json.len else case.binary.len;
        }

        pub fn runner(case: *const Self, operation: Operation) Runner(Self) {
            return .{ .case = case, .operation = operation };
        }
    };
}

/// Decoding either form gives back the message: the walk folds it into the same sum, and
/// encoding the binary decode again gives the same bytes.
fn check(comptime C: type, case: *const C) !void {
    const T = C.Message;
    const buffers = case.buffers;
    const decoded = try proto.decode(T, case.binary);
    if (try C.walk_message(&decoded) != case.sum) return error.WalkMismatch;
    // With storage, the decode gives the same message back.
    const stored = try proto.decode_into(T, case.binary, &buffers.storage);
    if (try C.walk_message(&stored) != case.sum) return error.WalkMismatch;
    const stored_again = try proto.encode(T, &stored, &buffers.encode_scratch);
    if (!std.mem.eql(u8, stored_again, case.binary)) return error.EncodingMismatch;
    const again = try proto.encode(T, &decoded, &buffers.encode_scratch);
    if (!std.mem.eql(u8, again, case.binary)) return error.EncodingMismatch;
    const from_json = try proto.decode_json(T, case.json, &buffers.transcoded, &buffers.tokens);
    if (try C.walk_message(&from_json) != case.sum) return error.WalkMismatch;
}

/// Runs one operation on one case, as many times as `run` is asked.
pub fn Runner(comptime C: type) type {
    return struct {
        const Self = @This();
        case: *const C,
        operation: Operation,

        /// Reads the buffers' address once, before the loop, so each step takes it from a
        /// register and not from the case.
        pub fn run(self: Self, iterations: u64) !void {
            const buffers = self.case.buffers;
            switch (self.operation) {
                inline else => |operation| for (0..iterations) |_| try step(C, self.case, buffers, operation),
            }
        }
    };
}

fn step(comptime C: type, case: *const C, buffers: *Buffers, comptime operation: Operation) !void {
    const T = C.Message;
    const walk = C.walk_message;
    switch (operation) {
        .binary_encode => keep((try proto.encode(T, case.input, &buffers.encode_scratch)).len),
        .binary_decode => keep(&try proto.decode(T, case.binary)),
        .binary_decode_walk => keep(try walk(&try proto.decode_into(T, case.binary, &buffers.storage))),
        .json_encode => keep((try proto.encode_json(T, case.input, &buffers.json_scratch)).len),
        .json_decode => keep(&try proto.decode_json(T, case.json, &buffers.transcoded, &buffers.tokens)),
        .json_decode_walk => keep(try walk(&try proto.decode_json(T, case.json, &buffers.transcoded, &buffers.tokens))),
    }
}

/// Keeps the optimizer from dropping work whose result nothing reads.
fn keep(value: anytype) void {
    std.mem.doNotOptimizeAway(value);
}
