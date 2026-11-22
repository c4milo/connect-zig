//! The program whose build `tools/compile_time_check.sh` times (decision 47). It holds the
//! generated code of the check's schema and validates one message of it, so the compiler reads,
//! types and unfolds each rule of the schema. What the program prints is no part of the check.
const std = @import("std");
const protovalidate = @import("protovalidate");
const schema = @import("schema");
const options = @import("options");

/// The octets of the violations one message may give.
const report_len = 65_536;
const io_buffer_len = 256;

const State = struct {
    report_storage: [report_len]u8 align(@alignOf(protovalidate.Violation)),
    out_buffer: [io_buffer_len]u8,
};

pub fn main(init: std.process.Init) !void {
    const state = try init.arena.allocator().create(State);
    var report: protovalidate.Report = .init(&state.report_storage);
    const message: schema.All = .{};
    protovalidate.validate(schema.All, &message, .{ .cpu_features = .detect() }, &report) catch |failure| switch (failure) {
        error.Invalid => {},
        else => return failure,
    };
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &state.out_buffer);
    // The build's number differs for each timed build, so the compiler builds each one.
    try stdout.interface.print("build {d}: {d} violations\n", .{ options.nonce, report.violations().len });
    try stdout.interface.flush();
}
