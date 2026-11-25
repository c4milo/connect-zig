//! Example: errors, and the typed details they carry, in each protocol.
//!
//! Divide in the calculator service fails with invalid_argument when the divisor is 0, and
//! attaches an `errors.v1.DivisionByZero` message as a detail. The client reads the detail back
//! in each protocol: from the Connect error body, from gRPC's grpc-status-details-bin header, and
//! from gRPC-Web's trailers frame. A call to a method the server lacks fails with unimplemented.
//! One round runs over h2, and one over h3.
//!
//! Run it with `zig build run`.
const std = @import("std");
const connect = @import("connect_zig").connect;
const proto = @import("connect_zig").protobuf;
const client = @import("connect_zig").colibri.client;
const harness = @import("harness");
const errors = @import("errors");
const constants = @import("constants.zig");
const app_file = @import("app.zig");
const App = app_file.App;
const Router = app_file.Router;
const CalculatorService = errors.CalculatorService;

pub const Error = error{CallWrong};

/// A method the server does not serve, which a client of an older or newer schema might call.
const missing: connect.Method = .{
    .service = CalculatorService.service_name,
    .name = "Multiply",
    .Request = errors.DivideRequest,
    .Response = errors.DivideResponse,
    .stream_type = .unary,
};

const DivideCall = harness.Call(CalculatorService.divide, .{});
const MissingCall = harness.Call(missing, .{});

/// The protocol and codec of each call that divides by zero.
const zero_options = [_]connect.client.Options{
    .{ .protocol = .connect, .codec = .json },
    .{ .protocol = .grpc },
    .{ .protocol = .grpc_web },
};

/// All the program holds, which `main` allocates once (decision 42). colibri reads and writes
/// each call until its round ends, so the calls live here.
const State = struct {
    app: App,
    /// What the program's calls share: the CPU features it detected (decision 51).
    client: connect.Client,
    /// Decodes the detail of an error, with the CPU features the program detected once.
    protobuf_decoder: proto.Decoder,
    rounds: harness.Rounds(App, Router),
    by_zero: [zero_options.len]DivideCall,
    by_two: DivideCall,
    multiply: MissingCall,
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    // The program detects the CPU's features once, as it starts.
    state.app = .{ .cpu_features = .detect() };
    // One client for every call, with the CPU features the program detected.
    state.client = .{ .cpu_features = state.app.cpu_features };
    state.protobuf_decoder = .init(state.app.cpu_features);
    try state.rounds.init(&state.app);
    defer state.rounds.deinit();
    try round(state, .{ .h11 = false, .h3 = false }, .h2);
    try round(state, .{ .h11 = false, .h2 = false }, .h3);
    std.debug.print("errors: every call answered as expected over h2 and h3\n", .{});
}

fn round(state: *State, protocols: client.Protocols, expected: client.Protocol) !void {
    const rounds = &state.rounds;
    try rounds.begin(protocols);
    for (&state.by_zero, zero_options) |*by_zero, options| {
        try by_zero.init(&state.client, {}, &options, &.{.{ .dividend = constants.dividend, .divisor = 0 }});
        try rounds.request(&by_zero.call.request, &by_zero.call.response);
    }
    try state.by_two.init(&state.client, {}, &.{ .codec = .json }, &.{.{ .dividend = constants.dividend, .divisor = constants.divisor }});
    try rounds.request(&state.by_two.call.request, &state.by_two.call.response);
    try state.multiply.init(&state.client, {}, &.{}, &.{.{}});
    try rounds.request(&state.multiply.call.request, &state.multiply.call.response);
    try rounds.finish(expected);

    for (&state.by_zero, zero_options) |*by_zero, options| try expect_detail(state, by_zero, options.protocol);
    try expect_quotient(state);
    var missed = state.multiply.call.read(rounds.storage());
    if (try missed.next(errors.DivideResponse) != null) return error.CallWrong;
    const failure = missed.failure orelse return error.CallWrong;
    if (failure.code != .unimplemented) return error.CallWrong;
    std.debug.print("errors: over {s}, {s} answered {s}\n", .{ @tagName(expected), comptime missing.path(), failure.code.name() });
}

/// Checks a call failed with invalid_argument and a DivisionByZero detail that names the dividend.
fn expect_detail(state: *State, by_zero: *const DivideCall, protocol: connect.Protocol) !void {
    var response = by_zero.call.read(state.rounds.storage());
    if (try response.next(errors.DivideResponse) != null) return error.CallWrong;
    const failure = response.failure orelse return error.CallWrong;
    if (failure.code != .invalid_argument or failure.details.len != 1) return error.CallWrong;
    const detail = failure.details[0];
    // A detail names its message type, so a client decodes only the details it knows.
    if (!std.mem.eql(u8, detail.type_name, errors.DivisionByZero.protobuf.full_name)) return error.CallWrong;
    const decoded = try state.protobuf_decoder.decode(errors.DivisionByZero, detail.value);
    if (decoded.dividend != constants.dividend) return error.CallWrong;
    std.debug.print("errors: over {s}: {s}: {s}, detail {s}{{ dividend: {d} }}\n", .{
        @tagName(protocol), failure.code.name(), failure.message, detail.type_name, decoded.dividend,
    });
}

fn expect_quotient(state: *State) !void {
    var response = state.by_two.call.read(state.rounds.storage());
    const answer = try response.next(errors.DivideResponse) orelse return error.CallWrong;
    if (answer.quotient != constants.dividend / constants.divisor or answer.remainder != constants.dividend % constants.divisor) return error.CallWrong;
    try harness.expect_end(&response, errors.DivideResponse);
}
