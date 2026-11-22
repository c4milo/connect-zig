//! The Zig side of the CEL differential check (`tools/cel_differential_check.sh`, decision 47).
//!
//! The check writes a schema of random CEL rules, one message type for each rule: M0, M1 and
//! so on, each with the same fields. This program holds the generated code of that schema. It
//! reads a file of encoded messages, one a line in hexadecimal digits, validates each message
//! as each type, and prints one line for each pair: the type's number, the message's number
//! and the verdict. The reference, protovalidate-go, prints the same lines, and the check
//! compares the two.
//!
//! A rule the module cannot check stops no build here: the program reads `rules_error` and
//! prints "refused" for the type, with the problem on standard error.
const std = @import("std");
const proto = @import("protobuf");
const protovalidate = @import("protovalidate");
const codec = @import("codec");
const rules = @import("schema");

/// The most rules one schema of the check holds.
const types_max = 4096;
/// The octets of the file of messages, at most.
const messages_text_len_max = 1_048_576;
/// The octets of one encoded message, at most.
const message_len_max = 4096;
/// The octets of the violations one message may give.
const report_len = 16_384;
const io_buffer_len = 65_536;
/// The branches the compiler may take to count the schema's types and to name each one: a
/// hundred for each type.
const count_branches_max = 409_600;
const hexadecimal_base = 16;
/// The hexadecimal digits of one octet.
const octet_digits = 2;

const State = struct {
    text: [messages_text_len_max]u8,
    message: [message_len_max]u8,
    report_storage: [report_len]u8 align(@alignOf(protovalidate.Violation)),
    out_buffer: [io_buffer_len]u8,
    /// The CPU features each rule's regular expressions search with, detected once.
    cpu_features: codec.Features,
};

pub const Error = error{ Usage, MessagesTooLarge, MessageTooLarge, WrongDigits };

fn type_name(comptime index: usize) []const u8 {
    return std.fmt.comptimePrint("M{d}", .{index});
}

/// The types the schema holds: M0 up to the first number it lacks.
const types_len = count: {
    @setEvalBranchQuota(count_branches_max);
    var count: usize = 0;
    for (0..types_max) |index| {
        if (!@hasDecl(rules, type_name(index))) break;
        count += 1;
    }
    break :count count;
};

pub fn main(init: std.process.Init) !void {
    const state = try init.arena.allocator().create(State);
    state.cpu_features = .detect();
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.Usage;
    const text = std.Io.Dir.cwd().readFile(init.io, path, &state.text) catch return error.MessagesTooLarge;
    if (text.len == state.text.len) return error.MessagesTooLarge;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &state.out_buffer);
    @setEvalBranchQuota(count_branches_max);
    inline for (0..types_len) |index| try check(@field(rules, type_name(index)), index, state, text, &stdout.interface);
    try stdout.interface.flush();
}

/// Validates each message of `text` as a `T`, and writes each verdict.
fn check(comptime T: type, comptime index: usize, state: *State, text: []const u8, out: *std.Io.Writer) !void {
    const problem = comptime protovalidate.rules_error(T);
    if (problem) |why| std.debug.print("M{d} is refused: {s}\n", .{ index, why });
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var number: usize = 0;
    // Each line holds a digit at least, so the text's length bounds the lines.
    for (0..text.len) |_| {
        const line = lines.next() orelse return;
        if (problem != null) {
            try out.print("{d} {d} refused\n", .{ index, number });
        } else {
            try out.print("{d} {d} ", .{ index, number });
            try verdict(T, state, try octets_of(line, &state.message), out);
        }
        number += 1;
    }
}

/// The octets a line of hexadecimal digits states.
fn octets_of(line: []const u8, out: []u8) Error![]const u8 {
    if (line.len % octet_digits != 0) return error.WrongDigits;
    const len = line.len / octet_digits;
    if (len > out.len) return error.MessageTooLarge;
    for (out[0..len], 0..) |*octet, place| {
        octet.* = std.fmt.parseInt(u8, line[place * octet_digits ..][0..octet_digits], hexadecimal_base) catch return error.WrongDigits;
    }
    return out[0..len];
}

/// One message's verdict as the reference writes it: "valid", "invalid:" and the violation's
/// message, or "fails" for an expression that fails as it runs.
fn verdict(comptime T: type, state: *State, encoded: []const u8, out: *std.Io.Writer) !void {
    const message = proto.decode(T, encoded) catch |failure| return out.print("undecoded:{t}\n", .{failure});
    var report: protovalidate.Report = .init(&state.report_storage);
    protovalidate.validate(T, &message, .{ .cpu_features = state.cpu_features }, &report) catch |failure| switch (failure) {
        error.Invalid => return out.print("invalid:{s}\n", .{report.violations()[0].message orelse ""}),
        else => return out.writeAll("fails\n"),
    };
    try out.writeAll("valid\n");
}
