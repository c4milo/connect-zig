//! Example: errors, and the typed details they carry, in each protocol.
//!
//! Divide in `services/demo.zig` fails with invalid_argument when the divisor is 0, and attaches
//! a `demo.v1.DivisionByZero` message as a detail. The client reads the detail back in each
//! protocol: from the Connect error body, from gRPC's grpc-status-details-bin header, and from
//! gRPC-Web's trailers frame. A call to a method the server lacks fails with unimplemented. One
//! round runs over h2, and one over h3.
//!
//! Run it with `zig build example-errors`.
const std = @import("std");
const connect = @import("connect");
const proto = @import("protobuf");
const client = @import("client");
const rpc = @import("connect_colibri");
const demo = @import("demo");
const harness = @import("services/link_client.zig");
const Service = demo.DemoService;

const calls_count = 5;
const dividend = 7;
const divisor = 2;

pub const Error = error{CallWrong};

/// A method the server does not serve, which a client of an older or newer schema might call.
const missing: connect.Method = .{
    .service = Service.service_name,
    .name = "Multiply",
    .Request = demo.DivideRequest,
    .Response = demo.DivideResponse,
    .stream_type = .unary,
};

const Divide = rpc.ClientCall(Service.divide, .{});
var by_zero: [3]Divide align(@alignOf(Divide)) = undefined;
var by_two: Divide align(@alignOf(Divide)) = undefined;
var multiply: rpc.ClientCall(missing, .{}) align(@alignOf(rpc.ClientCall(missing, .{}))) = undefined;
var buffers: [calls_count]harness.CallBuffers align(@alignOf(harness.CallBuffers)) = undefined;

/// The protocol and codec of each call that divides by zero.
const zero_options = [_]connect.client.Options{
    .{ .protocol = .connect, .codec = .json },
    .{ .protocol = .grpc },
    .{ .protocol = .grpc_web },
};

pub fn main() !void {
    try harness.init();
    defer harness.deinit();
    try round(.{ .h11 = false, .h3 = false }, .h2);
    try round(.{ .h11 = false, .h2 = false }, .h3);
    std.debug.print("errors: every call answered as expected over h2 and h3\n", .{});
}

fn round(protocols: client.Protocols, expected: client.Protocol) !void {
    try harness.begin(protocols);
    for (&by_zero, zero_options, 0..) |*client_call, options, index| {
        try client_call.init(&options, &.{.{ .dividend = dividend, .divisor = 0 }}, &harness.buffers(&buffers[index]));
        try harness.request(&client_call.request, &client_call.response);
    }
    try by_two.init(&.{ .codec = .json }, &.{.{ .dividend = dividend, .divisor = divisor }}, &harness.buffers(&buffers[3]));
    try harness.request(&by_two.request, &by_two.response);
    try multiply.init(&.{}, &.{.{}}, &harness.buffers(&buffers[4]));
    try harness.request(&multiply.request, &multiply.response);
    try harness.finish(expected);

    for (&by_zero, zero_options) |*client_call, options| try expect_detail(client_call, options.protocol);
    try expect_quotient();
    var missed = multiply.read(harness.storage());
    if (try missed.next(demo.DivideResponse) != null) return error.CallWrong;
    const failure = missed.failure orelse return error.CallWrong;
    if (failure.code != .unimplemented) return error.CallWrong;
    std.debug.print("errors: over {s}, {s} answered {s}\n", .{ @tagName(expected), comptime missing.path(), failure.code.name() });
}

/// Checks a call failed with invalid_argument and a DivisionByZero detail that names the dividend.
fn expect_detail(client_call: *const Divide, protocol: connect.Protocol) !void {
    var response = client_call.read(harness.storage());
    if (try response.next(demo.DivideResponse) != null) return error.CallWrong;
    const failure = response.failure orelse return error.CallWrong;
    if (failure.code != .invalid_argument or failure.details.len != 1) return error.CallWrong;
    const detail = failure.details[0];
    // A detail names its message type, so a client decodes only the details it knows.
    if (!std.mem.eql(u8, detail.type_name, demo.DivisionByZero.protobuf.full_name)) return error.CallWrong;
    const decoded = try proto.decode(demo.DivisionByZero, detail.value);
    if (decoded.dividend != dividend) return error.CallWrong;
    std.debug.print("errors: over {s}: {s}: {s}, detail {s}{{ dividend: {d} }}\n", .{
        @tagName(protocol), failure.code.name(), failure.message, detail.type_name, decoded.dividend,
    });
}

fn expect_quotient() !void {
    var response = by_two.read(harness.storage());
    const answer = try response.next(demo.DivideResponse) orelse return error.CallWrong;
    if (answer.quotient != dividend / divisor or answer.remainder != dividend % divisor) return error.CallWrong;
    try harness.expect_end(&response, demo.DivideResponse);
}
