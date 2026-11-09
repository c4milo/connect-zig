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
const service = @import("connectrpc_conformance_v1_service");
const client_compat = @import("connectrpc_conformance_v1_client_compat");
const constants = @import("constants.zig");
const transport = @import("client_transport.zig");
const plan_module = @import("client_plan.zig");
const Invocation = @import("client_invoke.zig").Invocation;
const result_module = @import("client_result.zig");

/// The types an Any in a JSON message may name (decision 21).
pub const protobuf_any_types = @import("any_types.zig").types;

comptime {
    // chapulin's hook, which every program over colibri's `tls` defines (colibri decision 94).
    _ = @import("hooks.zig");
}

const Service = service.ConformanceService;
const Request = client_compat.ClientCompatRequest;

var gzip_decoder: connect.GzipDecoder align(@alignOf(connect.GzipDecoder)) = undefined;
var gzip_encoder: connect.GzipEncoder align(@alignOf(connect.GzipEncoder)) = undefined;
var zstd_decoder: connect.ZstdDecoder align(@alignOf(connect.ZstdDecoder)) = undefined;
var zstd_encoder: connect.ZstdEncoder align(@alignOf(connect.ZstdEncoder)) = undefined;
var brotli_decoder: connect.BrotliDecoder align(@alignOf(connect.BrotliDecoder)) = undefined;
const codings: plan_module.Codings = .{
    .encoders = .{ .gzip = &gzip_encoder, .zstd = &zstd_encoder },
    .decoders = .{ .gzip = &gzip_decoder, .zstd = &zstd_decoder, .brotli = &brotli_decoder },
};

var request_bytes: [constants.client_compat_request_bytes]u8 = undefined;
var result_bytes: [constants.client_compat_response_bytes]u8 = undefined;
var response_bytes: [constants.client_compat_response_bytes]u8 = undefined;
var header_lines: [connect.client.request_headers_max]connect.Header align(@alignOf(connect.Header)) = undefined;

pub fn main(init: std.process.Init) !void {
    transport.init(init.io);
    var stdin_buffer: [constants.length_prefix_len]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var stdout_buffer: [constants.length_prefix_len]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    for (0..constants.client_cases_max) |_| {
        const bytes = try read_request(&stdin.interface) orelse return;
        const request = try proto.decode(Request, bytes);
        const response = try run_case(&request);
        try write_response(&stdout.interface, response);
    }
    return error.TooManyCases;
}

/// Reads one length-prefixed ClientCompatRequest, or null at the end of stdin.
fn read_request(stdin: *std.Io.Reader) !?[]const u8 {
    var prefix: [constants.length_prefix_len]u8 = undefined;
    stdin.readSliceAll(&prefix) catch |failure| switch (failure) {
        error.EndOfStream => return null,
        else => |other| return other,
    };
    // docs/testing_clients.md: "a network-byte-order (i.e. big-endian) 32-bit integer".
    const len = std.mem.readInt(u32, &prefix, .big);
    if (len > request_bytes.len) return error.RequestTooLarge;
    try stdin.readSliceAll(request_bytes[0..len]);
    return request_bytes[0..len];
}

fn write_response(stdout: *std.Io.Writer, response: []const u8) !void {
    var prefix: [constants.length_prefix_len]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(response.len), .big);
    try stdout.writeAll(&prefix);
    try stdout.writeAll(response);
    try stdout.flush();
}

/// Runs one case, and returns its ClientCompatResponse: the call's result, or why the client
/// could not make it.
fn run_case(request: *const Request) ![]const u8 {
    var result: result_module.Result = .{ .bytes = &result_bytes };
    dispatch(request, &result) catch |failure| return result_module.refusal(request.test_name, @errorName(failure), &response_bytes);
    return result.finish(request.test_name, &response_bytes);
}

/// Calls the method the case names. docs/testing_clients.md: a client "only needs to handle"
/// ConformanceService, and sends back an error for any other.
fn dispatch(request: *const Request, result: *result_module.Result) !void {
    if (request.service) |name| {
        if (!std.mem.eql(u8, name, Service.service_name)) return error.UnknownService;
    }
    const name = request.method orelse return error.NoMethod;
    const plan = try plan_module.plan_of(request, &codings, &header_lines);
    try transport.begin(request.host, std.math.cast(u16, request.port) orelse return error.InvalidPort, plan.protocols, plan.tls);
    defer transport.end();
    inline for (.{ Service.unary, Service.idempotent_unary, Service.unimplemented, Service.server_stream, Service.client_stream, Service.bidi_stream }) |method| {
        if (std.mem.eql(u8, name, method.name)) return invoke(method, request, &plan, result);
    }
    return error.UnknownMethod;
}

fn invoke(comptime method: connect.Method, request: *const Request, plan: *const plan_module.Plan, result: *result_module.Result) !void {
    const Messages = struct {
        var held: [constants.client_requests_max]method.Request align(@alignOf(method.Request)) = undefined;
    };
    const messages = try plan_module.messages_of(method.Request, request, &Messages.held);
    try Invocation(method).run(plan, messages, result);
}
