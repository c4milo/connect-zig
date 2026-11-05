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

pub const protobuf_any_types = .{ coverage.Everything, coverage.Nested, coverage.Scalars };

pub const Error = error{ UsageWrong, InputTooLarge };

/// The largest message a case holds, in either encoding.
const message_len_max = 1 << 20;
/// The longest JSON token: a string's octets.
const token_len_max = 1 << 16;
const io_buffer_len = 1 << 12;

const Direction = enum { @"json-to-binary", @"binary-to-json", @"binary-to-binary", @"through-partial" };
const Message = enum { coverage, editions, legacy };

var input: [message_len_max]u8 = undefined;
var output: [message_len_max]u8 = undefined;
var binary: [message_len_max]u8 = undefined;
var tokens: [token_len_max]u8 = undefined;
var io_buffer: [io_buffer_len]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const message = std.meta.stringToEnum(Message, args.next() orelse return error.UsageWrong) orelse return error.UsageWrong;
    const direction = std.meta.stringToEnum(Direction, args.next() orelse return error.UsageWrong) orelse return error.UsageWrong;
    var stdin = std.Io.File.stdin().reader(init.io, &io_buffer);
    const len = try stdin.interface.readSliceShort(&input);
    if (len == input.len) return error.InputTooLarge;
    const written = switch (message) {
        .coverage => try convert(coverage.Everything, direction, input[0..len]),
        .editions => try convert(editions.Everything, direction, input[0..len]),
        .legacy => try convert(legacy.Everything, direction, input[0..len]),
    };
    var stdout = std.Io.File.stdout().writer(init.io, &io_buffer);
    try stdout.interface.writeAll(written);
    try stdout.interface.flush();
}

fn convert(comptime T: type, direction: Direction, bytes: []const u8) ![]const u8 {
    switch (direction) {
        .@"json-to-binary" => {
            const message = try proto.decode_json(T, bytes, &binary, &tokens);
            return proto.encode(T, &message, &output);
        },
        .@"binary-to-json" => {
            const message = try proto.decode(T, bytes);
            return proto.encode_json(T, &message, &output);
        },
        .@"binary-to-binary" => {
            const message = try proto.decode(T, bytes);
            return proto.encode(T, &message, &output);
        },
        .@"through-partial" => {
            const message = try proto.decode(coverage.Partial, bytes);
            return proto.encode(coverage.Partial, &message, &output);
        },
    }
}
