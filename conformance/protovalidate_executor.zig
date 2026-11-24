//! The program protovalidate's conformance harness tests (decision 47). The harness writes one
//! `TestConformanceRequest` on stdin: the descriptors of the suite's schemas, and each case's
//! message as an Any under the case's name. It reads one `TestConformanceResponse` on stdout:
//! each case's result under its name ("buf/validate/conformance/harness/harness.proto").
//!
//! connect-zig has no dynamic message, so the program holds the generated code of every schema
//! of the suite, and finds a case's type by the name its Any states (decision 21). It reads no
//! descriptor of the request.
const std = @import("std");
const proto = @import("protobuf");
const protovalidate = @import("protovalidate");
const platform = @import("platform");
const harness = @import("harness");
const cases = @import("cases");
const constants = @import("constants.zig");

/// All the program holds, which `main` allocates once before the first case (decision 42).
const State = struct {
    request_bytes: [constants.executor_request_bytes_max]u8,
    result_bytes: [constants.executor_result_bytes]u8,
    report_storage: [constants.executor_report_bytes]u8 align(@alignOf(protovalidate.Violation)),
    in_buffer: [constants.executor_io_buffer_len]u8,
    out_buffer: [constants.executor_io_buffer_len]u8,
    /// The CPU features each rule's regular expressions search with, detected once.
    cpu_features: platform.CpuFeatures,
};

const Result = @typeInfo(@FieldType(harness.TestResult, "result")).optional.child;
const Entry = harness.TestConformanceResponse.ResultsEntry;

pub const Error = error{ RequestTooLarge, TooManyCases };

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    state.cpu_features = .detect();
    var stdin = std.Io.File.stdin().reader(init.io, &state.in_buffer);
    const len = try stdin.interface.readSliceShort(&state.request_bytes);
    if (len == state.request_bytes.len) return error.RequestTooLarge;
    const request = try proto.decode(harness.TestConformanceRequest, state.request_bytes[0..len]);
    const now = time_of(std.Io.Timestamp.now(init.io, .real));
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &state.out_buffer);
    var each = request.cases.iterator();
    for (0..constants.executor_cases_max) |_| {
        const case = try each.next() orelse return stdout.interface.flush();
        // Each result is a response of its own. Two encodings of one message, one after the
        // other, decode as their merge ("Last One Wins", encoding guide), so the harness reads
        // one response that holds every result.
        const entry: [1]Entry = .{.{ .key = case.key, .value = .{ .result = respond(state, case, now) } }};
        const response: harness.TestConformanceResponse = .{ .results = .of(&entry) };
        try stdout.interface.writeAll(try proto.encode(harness.TestConformanceResponse, &response, &state.result_bytes));
    }
    return error.TooManyCases;
}

/// The time as `validate` takes it: seconds since the epoch and the nanoseconds past them.
fn time_of(timestamp: std.Io.Timestamp) proto.wkt.Timestamp {
    return .{
        .seconds = @intCast(@divFloor(timestamp.nanoseconds, constants.executor_nanos_per_second)),
        .nanos = @intCast(@mod(timestamp.nanoseconds, constants.executor_nanos_per_second)),
    };
}

/// The message types of `Container`: each generated message it declares, and each one those
/// declare. A map's entry is no message of its own.
fn messages_of(comptime Container: type) []const type {
    comptime {
        @setEvalBranchQuota(constants.executor_eval_branches);
        var list: []const type = &.{};
        for (@typeInfo(Container).@"struct".decls) |declaration| {
            const Declared = @field(Container, declaration.name);
            if (@TypeOf(Declared) != type or !is_message(Declared)) continue;
            if (!Declared.protobuf.map_entry) list = list ++ [_]type{Declared};
            list = list ++ messages_of(Declared);
        }
        return list;
    }
}

fn is_message(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "protobuf") and @TypeOf(T.protobuf) == proto.Descriptor;
}

/// The result of one case: its message, named by its Any, checked against its rules.
fn respond(state: *State, case: *const harness.TestConformanceRequest.CasesEntry, now: proto.wkt.Timestamp) Result {
    const any = case.value orelse return .{ .unexpected_error = "the case holds no message" };
    // An Any's URL ends with the message's full name, after its last "/" (any.proto).
    const slash = std.mem.lastIndexOfScalar(u8, any.type_url, '/');
    const name = any.type_url[if (slash) |at| at + 1 else 0..];
    inline for (cases.modules) |module| {
        if (respond_in(module, state, name, any.value, now)) |result| return result;
    }
    // A case's message may be a well-known type itself, which has no rule.
    if (respond_in(proto.wkt, state, name, any.value, now)) |result| return result;
    return .{ .unexpected_error = "the executor holds no message of this name" };
}

fn respond_in(comptime module: type, state: *State, name: []const u8, value: []const u8, now: proto.wkt.Timestamp) ?Result {
    inline for (comptime messages_of(module)) |T| {
        if (std.mem.eql(u8, name, T.protobuf.full_name)) return check(T, state, value, now);
    }
    return null;
}

fn check(comptime T: type, state: *State, value: []const u8, now: proto.wkt.Timestamp) Result {
    // Rules the library cannot check stop a program's build. The harness expects such a type
    // to answer with a compilation error, so the program reads the problem and never calls
    // `validate` for the type.
    if (comptime protovalidate.rules_error(T)) |problem| return .{ .compilation_error = problem };
    const message = proto.decode(T, value) catch |failure| return .{ .unexpected_error = @errorName(failure) };
    var report: protovalidate.Report = .init(&state.report_storage);
    protovalidate.validate(T, &message, .{ .cpu_features = state.cpu_features, .now = now }, &report) catch |failure| switch (failure) {
        error.Invalid => return .{ .validation_error = .{ .violations = .of(report.violations()) } },
        else => return .{ .runtime_error = @errorName(failure) },
    };
    return .{ .success = true };
}
