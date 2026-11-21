//! connect-zig's Lean model (spec/README.md), built by pepegrillo's lake runner. After the
//! model builds, the vector file it gives is checked against the committed one beside the Zig
//! grammar, which a unit test of `protovalidate` replays.
//!
//! Run: `zig build lean`, or `zig build lean -- write` to rewrite the vector file.
const std = @import("std");
const pepegrillo = @import("pepegrillo");

/// The Lean project, from the repository's root. It pins its release in `lean-toolchain`.
const directory = "spec/lean";
/// The directory of the vector file, from the Lean project, where lake runs.
const vector_directory = "../../src/protovalidate/cel";

const model: pepegrillo.lean.Config = .{ .directory = directory };
const check_vectors: pepegrillo.lean.Config = .{
    .directory = directory,
    .lake_arguments = &.{ "exe", "vectors", "--check", vector_directory },
};
const write_vectors: pepegrillo.lean.Config = .{
    .directory = directory,
    .lake_arguments = &.{ "exe", "vectors", "--write", vector_directory },
};

const exit_usage: u8 = 2;
/// The arguments of a run that names what to do with the vectors: the program, and "write".
const arguments_with_mode = 2;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    const write = arguments.len == arguments_with_mode and std.mem.eql(u8, arguments[1], "write");
    if (arguments.len > arguments_with_mode or (arguments.len == arguments_with_mode and !write)) {
        std.debug.print("usage: lean [write]\n", .{});
        std.process.exit(exit_usage);
    }
    var error_buffer: [std.heap.page_size_min]u8 = undefined;
    var errors = std.Io.File.stderr().writerStreaming(init.io, &error_buffer);
    defer errors.interface.flush() catch {};
    // The engine writes its own lines to `errors` and nothing to `out`. lake's output goes to
    // the terminal.
    const context: pepegrillo.Context = .{
        .arena = arena,
        .io = init.io,
        .environ = init.environ_map,
        .out = &errors.interface,
        .errors = &errors.interface,
    };
    const built = try pepegrillo.lean.run(&context, model, &.{});
    if (built != 0) std.process.exit(built);
    const vectors = if (write)
        try pepegrillo.lean.run(&context, write_vectors, &.{})
    else
        try pepegrillo.lean.run(&context, check_vectors, &.{});
    errors.interface.flush() catch {};
    std.process.exit(vectors);
}
