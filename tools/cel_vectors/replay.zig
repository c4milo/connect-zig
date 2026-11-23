//! Replays a file of the Lean model's vectors against the Zig grammar (spec/README.md).
//!
//!     cel-vectors-replay <file>
//!
//! `lake exe vectors --random <seed> <count>` writes the file: a first line that says what the
//! file holds, then one line for each expression. A line is the expression, a tab, and the
//! text of the tree the model reads of it, or "!" for a text that is no expression. An octet
//! that is not printable ASCII, and "%", is "%" and two hexadecimal digits.
//!
//! The program reads each expression with the grammar the compiler runs, over a tree in its
//! own storage, and requires the model's tree, or a refusal where the model has none. It
//! prints each line that differs, and exits 1 when one does.
const std = @import("std");
const reader = @import("cel_reader");

/// The octets of the file of vectors, at most.
const file_len_max = 67_108_864;
/// The octets of one expression, at most.
const expression_len_max = 16_384;
/// The octets of a tree's text, at most: an octet of a bytes literal is written as four, and an
/// operator gains two brackets and two spaces.
const written_len_max = 131_072;
const io_buffer_len = 65_536;
/// The lines that differ which the program prints, at most.
const shown_max = 20;
const hexadecimal_base = 16;
/// The hexadecimal digits after a "%".
const pct_digits = 2;

const State = struct {
    file: [file_len_max]u8,
    items: [expression_len_max]reader.Item,
    links: [expression_len_max]reader.Index,
    pending: [expression_len_max]reader.Index,
    octets: [expression_len_max]u8,
    expression: [expression_len_max]u8,
    expected: [written_len_max]u8,
    written: [written_len_max]u8,
    out_buffer: [io_buffer_len]u8,
};

pub const Error = error{ Usage, FileTooLarge, LineTooLong, NoTab, WrongDigits };

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.Usage;
    const text = std.Io.Dir.cwd().readFile(init.io, path, &state.file) catch return error.FileTooLarge;
    if (text.len == state.file.len) return error.FileTooLarge;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &state.out_buffer);
    const out = &stdout.interface;
    var lines = std.mem.splitScalar(u8, text, '\n');
    // The file's first line says what the file holds. An expression may start with "#".
    _ = lines.next();
    var compared: usize = 0;
    var different: usize = 0;
    // Each line holds a tab at least, so the text's length bounds the lines.
    for (0..text.len) |_| {
        const line = lines.next() orelse break;
        if (line.len == 0) continue;
        compared += 1;
        if (try agrees(state, line)) continue;
        different += 1;
        if (different <= shown_max) try out.print("DIFFERENT {s}\n  the Zig grammar reads: {s}\n", .{ line, state.written[0..written_len(state)] });
    }
    try out.print("{d} expressions: the Zig grammar and the Lean model differ on {d}\n", .{ compared, different });
    try out.flush();
    if (different != 0) std.process.exit(1);
}

/// The octets of the last text `read` wrote, up to the first octet that is 0.
fn written_len(state: *const State) usize {
    return std.mem.indexOfScalar(u8, &state.written, 0) orelse state.written.len;
}

/// Whether the Zig grammar reads a line's expression as the line says the model does.
fn agrees(state: *State, line: []const u8) !bool {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.NoTab;
    const expression = try column(line[0..tab], &state.expression);
    const expected = try column(line[tab + 1 ..], &state.expected);
    const read_text = try read(state, expression);
    if (std.mem.eql(u8, expected, "!")) return read_text == null;
    return std.mem.eql(u8, expected, read_text orelse return false);
}

/// The text of the tree the grammar reads of `expression`, or null for a text that is no
/// expression. A double is written as its text in the expression, as the model writes it.
fn read(state: *State, expression: []const u8) !?[]const u8 {
    var tree: reader.Tree = .{ .items = &state.items, .links = &state.links, .pending = &state.pending, .octets = &state.octets };
    @memset(&state.written, 0);
    var writer: std.Io.Writer = .fixed(&state.written);
    switch (reader.parse(&tree, expression)) {
        .root => |root| try reader.write(&tree, root, .texts, &writer),
        .problem => {
            try writer.writeAll("no expression");
            return null;
        },
    }
    return writer.buffered();
}

/// The octets a column of the file states.
fn column(text: []const u8, out: []u8) Error![]const u8 {
    var len: usize = 0;
    var at: usize = 0;
    for (0..text.len) |_| {
        if (at == text.len) break;
        if (len == out.len) return error.LineTooLong;
        if (text[at] == '%') {
            if (text.len - at <= pct_digits) return error.WrongDigits;
            out[len] = std.fmt.parseInt(u8, text[at + 1 ..][0..pct_digits], hexadecimal_base) catch return error.WrongDigits;
            at += 1 + pct_digits;
        } else {
            out[len] = text[at];
            at += 1;
        }
        len += 1;
    }
    return out[0..len];
}
