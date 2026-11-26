//! The conformance client: connect-zig's client under the connectrpc conformance runner in client
//! mode (design §8 step 7, the client half). `tools/conformance_check.sh` runs it.
//!
//! The runner writes ClientCompatRequest messages to stdin, each after a 4-octet big-endian
//! length, and reads a ClientCompatResponse for each from stdout, in the same form
//! (connectconformance `--help`; docs/testing_clients.md, "Interacting with the test runner").
//! The client runs each case's call to its end before it reads the next, and exits at the end of
//! stdin. The runner ends it early with SIGTERM, whose default action ends the process.
const std = @import("std");
const connect = @import("connect");
const proto = @import("protobuf");
/// A check program decodes and encodes with the build target's CPU features: it runs on the
/// machine it was built for, and a library takes the features its program detected.
const protobuf_decoder: proto.Decoder = .init(.target());
const service = @import("connectrpc_conformance_v1_service");
const client_compat = @import("connectrpc_conformance_v1_client_compat");
const constants = @import("constants.zig");
const Transport = @import("client_transport.zig").Transport;
const Buffers = @import("client_buffers.zig").Buffers;
const plan_module = @import("client_plan.zig");
const Invocation = @import("client_invoke.zig").Invocation;
const result_module = @import("client_result.zig");

/// The types an Any in a JSON message may name (decision 21).
pub const protobuf_any_types = @import("any_types.zig").types;

const Service = service.ConformanceService;
const Request = client_compat.ClientCompatRequest;

/// One method's call, and the request messages a case gives it. colibri reads and writes the
/// call until it finished, so it lives in `State`.
fn Slot(comptime method: connect.Method) type {
    return struct {
        invocation: Invocation(method),
        messages: [constants.client_requests_max]method.Request,
    };
}

/// A slot for each method of ConformanceService, named as `Service` names the method.
const Slots = struct {
    unary: Slot(Service.unary),
    idempotent_unary: Slot(Service.idempotent_unary),
    unimplemented: Slot(Service.unimplemented),
    server_stream: Slot(Service.server_stream),
    client_stream: Slot(Service.client_stream),
    bidi_stream: Slot(Service.bidi_stream),
};

/// All the program holds, which `main` allocates once before the first case (decision 42).
const State = struct {
    transport: Transport,
    buffers: Buffers,
    plan_memory: plan_module.Memory,
    result_lists: result_module.Lists,
    slots: Slots,
    gzip_decoder: connect.GzipDecoder,
    gzip_encoder: connect.GzipEncoder,
    zstd_decoder: connect.ZstdDecoder,
    zstd_encoder: connect.ZstdEncoder,
    brotli_decoder: connect.BrotliDecoder,
    brotli_encoder: connect.BrotliEncoder,
    /// What the program's calls share: the CPU features it detects once, and the coders above.
    client: connect.Client,
    request_bytes: [constants.client_compat_request_bytes]u8,
    result_bytes: [constants.client_compat_response_bytes]u8,
    response_bytes: [constants.client_compat_response_bytes]u8,
    stdin_buffer: [constants.length_prefix_len]u8,
    stdout_buffer: [constants.length_prefix_len]u8,
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    state.transport.init(init.io);
    state.client = .{
        .cpu_features = .detect(),
        .encoders = .{ .gzip = &state.gzip_encoder, .zstd = &state.zstd_encoder, .brotli = &state.brotli_encoder },
        .decoders = .{ .gzip = &state.gzip_decoder, .zstd = &state.zstd_decoder, .brotli = &state.brotli_decoder },
    };
    var stdin = std.Io.File.stdin().reader(init.io, &state.stdin_buffer);
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &state.stdout_buffer);
    for (0..constants.client_cases_max) |_| {
        const bytes = try read_request(state, &stdin.interface) orelse return;
        const request = try protobuf_decoder.decode(Request, bytes);
        const response = try run_case(state, &request);
        try write_response(&stdout.interface, response);
    }
    return error.TooManyCases;
}

/// Reads one length-prefixed ClientCompatRequest, or null at the end of stdin.
fn read_request(state: *State, stdin: *std.Io.Reader) !?[]const u8 {
    // docs/testing_clients.md: "a network-byte-order (i.e. big-endian) 32-bit integer".
    const len = stdin.takeInt(u32, .big) catch |failure| switch (failure) {
        error.EndOfStream => return null,
        else => |other| return other,
    };
    if (len > state.request_bytes.len) return error.RequestTooLarge;
    try stdin.readSliceAll(state.request_bytes[0..len]);
    return state.request_bytes[0..len];
}

fn write_response(stdout: *std.Io.Writer, response: []const u8) !void {
    try stdout.writeInt(u32, @intCast(response.len), .big);
    try stdout.writeAll(response);
    try stdout.flush();
}

/// Runs one case, and returns its ClientCompatResponse: the call's result, or why the client
/// could not make it.
fn run_case(state: *State, request: *const Request) ![]const u8 {
    var result: result_module.Result = .{ .bytes = &state.result_bytes, .lists = &state.result_lists };
    dispatch(state, request, &result) catch |failure| return result_module.refusal(request.test_name, @errorName(failure), &state.response_bytes);
    return result.finish(request.test_name, &state.response_bytes);
}

/// Calls the method the case names. docs/testing_clients.md: a client "only needs to handle"
/// ConformanceService, and sends back an error for any other.
fn dispatch(state: *State, request: *const Request, result: *result_module.Result) !void {
    if (request.service) |name| {
        if (!std.mem.eql(u8, name, Service.service_name)) return error.UnknownService;
    }
    const name = request.method orelse return error.NoMethod;
    const plan = try plan_module.plan_of(request, &state.client, &state.plan_memory, state.transport.crypto);
    try state.transport.begin(request.host, std.math.cast(u16, request.port) orelse return error.InvalidPort, plan.protocols, plan.tls, state.client.cpu_features);
    defer state.transport.end();
    inline for (@typeInfo(Slots).@"struct".fields) |field| {
        const method = @field(Service, field.name);
        if (std.mem.eql(u8, name, method.name)) return invoke(method, state, &@field(state.slots, field.name), request, &plan, result);
    }
    return error.UnknownMethod;
}

fn invoke(comptime method: connect.Method, state: *State, slot: *Slot(method), request: *const Request, plan: *const plan_module.Plan, result: *result_module.Result) !void {
    const messages = try plan_module.messages_of(method.Request, request, &slot.messages);
    try slot.invocation.run(&state.transport, &state.buffers, plan, messages, result);
}
