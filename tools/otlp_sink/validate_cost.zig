//! What validation costs the OTLP sink, by the storage its route decodes into (decision 37): for
//! each size, the median nanoseconds of `decode_into` and the span count, as the sink's route and
//! handler run them, and of the same with `protovalidate.validate` between them. A list past the
//! storage's end stays in the message, and validation decodes it again, so too little storage
//! shows as a cost of validation (tools/otlp_sink/constants.zig, `storage_bytes`).
//!
//!     zig build otlp-validate-cost -Drelease
//!     zig-out/bin/otlp-validate-cost <message.binpb> <iterations>
//!
//! The message is an `ExportTraceServiceRequest` of tools/fullstack/validate's schema, such as
//! the `.binpb` that tools/fullstack/production_request.py writes. This is a program: it reads a
//! file and the clock through `init.io`.
const std = @import("std");
const proto = @import("protobuf");
const protovalidate = @import("protovalidate");
const otlp = @import("otlp");
const platform = @import("platform");

/// The sizes of storage the program times, in octets: the route's default for the sink, 256 KiB,
/// then 512 KiB, 768 KiB, the sink's 1 MiB, and 4 MiB.
const storage_default = 262_144;
const storage_half = 524_288;
const storage_three_quarters = 786_432;
const storage_sink = 1_048_576;
const storage_most = 4_194_304;
const storages = [_]usize{ storage_default, storage_half, storage_three_quarters, storage_sink, storage_most };
/// The octets of the largest message the program reads.
const message_len_max = 4_194_304;
/// The octets of the report of a message's violations.
const report_len = 65_536;
/// The timed runs of each thing, whose median the program prints; odd, so one is the middle.
const runs = 7;
/// The median's place among the sorted runs, from 0.
const middle = 3;
/// The base of the iterations on the command line.
const decimal = 10;
/// Nanoseconds in a microsecond.
const nanoseconds_a_microsecond = 1000;

const State = struct {
    message: [message_len_max]u8,
    storage: [storages[storages.len - 1]]u8 align(@alignOf(u64)),
    report: [report_len]u8 align(@alignOf(protovalidate.Violation)),
};

fn count_spans(request: *const otlp.ExportTraceServiceRequest) !u64 {
    var total: u64 = 0;
    var resources = request.resource_spans.iterator();
    while (try resources.next()) |resource| {
        var scopes = resource.scope_spans.iterator();
        while (try scopes.next()) |scope| total += try scope.spans.count();
    }
    return total;
}

fn once(state: *State, bytes: []const u8, storage_len: usize, validate: bool, cpu_features: platform.CpuFeatures) !u64 {
    const message = try proto.decode_into(otlp.ExportTraceServiceRequest, bytes, state.storage[0..storage_len]);
    if (validate) {
        var report: protovalidate.Report = .init(&state.report);
        try protovalidate.validate(otlp.ExportTraceServiceRequest, &message, .{ .cpu_features = cpu_features }, &report);
    }
    return count_spans(&message);
}

fn median(io: std.Io, state: *State, bytes: []const u8, storage_len: usize, validate: bool, cpu_features: platform.CpuFeatures, iterations: u64) !f64 {
    var each: [runs]f64 = undefined;
    for (&each) |*value| {
        const start = std.Io.Timestamp.now(io, .awake);
        for (0..iterations) |_| std.mem.doNotOptimizeAway(try once(state, bytes, storage_len, validate, cpu_features));
        value.* = @as(f64, @floatFromInt(start.untilNow(io, .awake).toNanoseconds())) / @as(f64, @floatFromInt(iterations));
    }
    std.mem.sort(f64, &each, {}, std.sort.asc(f64));
    return each[middle];
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const path = args.next() orelse return error.Usage;
    const iterations = try std.fmt.parseInt(u64, args.next() orelse return error.Usage, decimal);
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    const bytes = try std.Io.Dir.cwd().readFile(init.io, path, &state.message);
    const cpu_features: platform.CpuFeatures = .detect();
    const spans = try once(state, bytes, storages[0], false, cpu_features);
    std.debug.print("{d} octets, {d} spans\n", .{ bytes.len, spans });
    for (storages) |storage_len| {
        const plain = try median(init.io, state, bytes, storage_len, false, cpu_features, iterations);
        const checked = try median(init.io, state, bytes, storage_len, true, cpu_features, iterations);
        std.debug.print("storage {d:>8}: decode {d:>9.0} ns, with validate {d:>9.0} ns, validate adds {d:>9.0} ns, {d:.3} µs a span\n", .{
            storage_len, plain, checked, checked - plain, (checked - plain) / nanoseconds_a_microsecond / @as(f64, @floatFromInt(spans)),
        });
    }
}
