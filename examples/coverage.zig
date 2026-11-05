//! A converter `tools/coverage_check.sh` runs to compare the protobuf runtime with Go's, through
//! `buf convert`: it reads one `coverage.v1.Everything` from stdin and writes it to stdout.
//!
//! ```sh
//! coverage json-to-binary < case.json > case.binpb
//! coverage binary-to-json < case.binpb > case.json
//! coverage binary-to-binary < case.binpb > again.binpb
//! ```
//!
//! An Any in the cases names coverage types, so the root file declares them (decision 21).
const std = @import("std");
const proto = @import("protobuf");
const coverage = @import("coverage");

pub const protobuf_any_types = .{ coverage.Everything, coverage.Nested, coverage.Scalars };

pub const Error = error{ UsageWrong, InputTooLarge };

/// The largest message a case holds, in either encoding.
const message_len_max = 1 << 20;
/// The longest JSON token: a string's octets.
const token_len_max = 1 << 16;
const io_buffer_len = 1 << 12;

const Direction = enum { @"json-to-binary", @"binary-to-json", @"binary-to-binary" };

var input: [message_len_max]u8 = undefined;
var output: [message_len_max]u8 = undefined;
var binary: [message_len_max]u8 = undefined;
var tokens: [token_len_max]u8 = undefined;
var io_buffer: [io_buffer_len]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const name = args.next() orelse return error.UsageWrong;
    const direction = std.meta.stringToEnum(Direction, name) orelse return error.UsageWrong;
    var stdin = std.Io.File.stdin().reader(init.io, &io_buffer);
    const len = try stdin.interface.readSliceShort(&input);
    if (len == input.len) return error.InputTooLarge;
    const written = try convert(direction, input[0..len]);
    var stdout = std.Io.File.stdout().writer(init.io, &io_buffer);
    try stdout.interface.writeAll(written);
    try stdout.interface.flush();
}

fn convert(direction: Direction, bytes: []const u8) ![]const u8 {
    switch (direction) {
        .@"json-to-binary" => {
            const message = try proto.decode_json(coverage.Everything, bytes, &binary, &tokens);
            return proto.encode(coverage.Everything, &message, &output);
        },
        .@"binary-to-json" => {
            const message = try proto.decode(coverage.Everything, bytes);
            return proto.encode_json(coverage.Everything, &message, &output);
        },
        .@"binary-to-binary" => {
            const message = try proto.decode(coverage.Everything, bytes);
            return proto.encode(coverage.Everything, &message, &output);
        },
    }
}
