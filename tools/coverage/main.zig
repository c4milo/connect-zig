//! A converter `tools/coverage_check.sh` runs to compare the protobuf runtime with Go's, through
//! `buf convert`: it reads one message from stdin and writes it to stdout. The first argument
//! names the message: `coverage` for `coverage.v1.Everything`, every proto3 type; `editions`
//! for `editions.v1.Everything`, edition 2023's features; `legacy` for `legacy.v1.Everything`,
//! proto2 and its groups.
//!
//! ```sh
//! coverage coverage json-to-binary < case.json > case.binpb
//! coverage editions binary-to-json < case.binpb > case.json
//! coverage legacy binary-to-binary < case.binpb > again.binpb
//! coverage coverage through-partial < case.binpb > again.binpb
//! ```
//!
//! `through-partial` reads an `Everything` as `coverage.v1.Partial`, which knows only its scalars,
//! and writes it back: every other field passes through as an unknown field (decision 24).
//!
//! An Any in the cases names coverage types, so the root file declares them (decision 21).
const std = @import("std");
const proto = @import("protobuf");
const coverage = @import("coverage");
const editions = @import("editions");
const legacy = @import("legacy");
const constants = @import("constants.zig");

pub const protobuf_any_types: []const type = &.{ coverage.Everything, coverage.Nested, coverage.Scalars };

pub const Error = error{ UsageWrong, InputTooLarge };

const Direction = enum { @"json-to-binary", @"binary-to-json", @"binary-to-binary", @"through-partial" };
const Message = enum { coverage, editions, legacy };

/// All the program holds, which `main` allocates once before the first call (decision 42).
const State = struct {
    input: [constants.message_len_max]u8,
    output: [constants.message_len_max]u8,
    binary: [constants.message_len_max]u8,
    tokens: [constants.token_len_max]u8,
    io_buffer: [constants.io_buffer_len]u8,
};

pub fn main(init: std.process.Init) !void {
    const state = try init.arena.allocator().create(State);
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const message = std.meta.stringToEnum(Message, args.next() orelse return error.UsageWrong) orelse return error.UsageWrong;
    const direction = std.meta.stringToEnum(Direction, args.next() orelse return error.UsageWrong) orelse return error.UsageWrong;
    var stdin = std.Io.File.stdin().reader(init.io, &state.io_buffer);
    const len = try stdin.interface.readSliceShort(&state.input);
    if (len == state.input.len) return error.InputTooLarge;
    const input = state.input[0..len];
    const written = switch (message) {
        .coverage => try convert(coverage.Everything, state, direction, input),
        .editions => try convert(editions.Everything, state, direction, input),
        .legacy => try convert(legacy.Everything, state, direction, input),
    };
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &state.io_buffer);
    try stdout.interface.writeAll(written);
    try stdout.interface.flush();
}

fn convert(comptime T: type, state: *State, direction: Direction, bytes: []const u8) ![]const u8 {
    switch (direction) {
        .@"json-to-binary" => {
            const message = try proto.decode_json(T, bytes, &state.binary, &state.tokens);
            return proto.encode(T, &message, &state.output);
        },
        .@"binary-to-json" => {
            const message = try proto.decode(T, bytes);
            return proto.encode_json(T, &message, &state.output);
        },
        .@"binary-to-binary" => {
            const message = try proto.decode(T, bytes);
            return proto.encode(T, &message, &state.output);
        },
        .@"through-partial" => {
            const message = try proto.decode(coverage.Partial, bytes);
            return proto.encode(coverage.Partial, &message, &state.output);
        },
    }
}
