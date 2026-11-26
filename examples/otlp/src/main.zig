//! Example: a client exports a trace to the OTLP receiver, then reads it back, over each protocol
//! the receiver speaks (decision 40).
//!
//! The trace is a checkout of three spans: a server span with an event, a database query with an
//! attribute of each kind OTLP carries, and a card charge that fails. Each round exports it once,
//! as OpenTelemetry's exporters do, and a second round reads every export back with
//! `SpanStore/Received`. The rounds run over h2 in gRPC, the protocol of OTLP's own exporters, over
//! h11 in Connect, and over h3 in gRPC, in memory through the harness.
//!
//! Anything other than the expected answers exits with an error, which is how `zig build test`
//! and CI know the example works. Run it with `zig build run`.
const std = @import("std");
const connect = @import("connect_zig").connect;
const client = @import("connect_zig").colibri.client;
const harness = @import("harness");
const otlp = @import("otlp");
const trace = @import("otlp_trace");
const common = @import("otlp_common");
const otlpstore = @import("otlpstore");
const service = @import("otlp_service");
const constants = @import("constants.zig");
const app_file = @import("app.zig");
const App = app_file.App;

pub const Error = error{CallWrong};

const ExportCall = harness.Call(otlp.TraceService.@"export", .{});
const ReceivedCall = harness.Call(otlpstore.SpanStore.received, .{});

/// All the program holds, which `main` allocates once (decision 42).
const State = struct {
    app: App,
    /// What the program's calls share: the CPU features it detected (decision 51).
    client: connect.Client,
    rounds: harness.Rounds(App, app_file.Router),
    export_call: ExportCall,
    received_call: ReceivedCall,
    /// The exports the receiver took so far, which `Received` must hold.
    exports: u64,
};

/// One protocol of the rounds: the options of its calls, the pool's protocols and the one it
/// must speak.
const Round = struct { options: connect.client.Options, protocols: client.Protocols, expected: client.Protocol };
const rounds = [_]Round{
    .{ .options = .{ .protocol = .grpc }, .protocols = .{ .h11 = false, .h3 = false }, .expected = .h2 },
    .{ .options = .{}, .protocols = .{ .h2 = false, .h3 = false }, .expected = .h11 },
    .{ .options = .{ .protocol = .grpc }, .protocols = .{ .h11 = false, .h2 = false }, .expected = .h3 },
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
    state.exports = 0;
    try state.rounds.init(&state.app, init.io);
    defer state.rounds.deinit();
    for (rounds) |round| {
        try export_trace(state, round);
        try expect_received(state, round);
        std.debug.print("otlp: over {s}, the receiver kept {d} spans of {d} exports\n", .{ @tagName(round.expected), state.app.otlp.taken, state.exports });
    }
    std.debug.print("otlp: every export answered and read back as expected over h2, h11 and h3\n", .{});
}

/// Exports the trace once, and checks the receiver took every span.
fn export_trace(state: *State, round: Round) !void {
    try state.rounds.begin(round.protocols);
    try state.export_call.init(&state.client, {}, &round.options, &.{checkout});
    try state.rounds.request(&state.export_call.call.request, &state.export_call.call.response);
    try state.rounds.finish(round.expected);
    var response = state.export_call.call.read(state.rounds.storage());
    const answer = try response.next(otlp.ExportTraceServiceResponse) orelse return error.CallWrong;
    try harness.expect_end(&response, otlp.ExportTraceServiceResponse);
    // A server that took every span answers with no partial success.
    if (answer.partial_success != null) return error.CallWrong;
    state.exports += 1;
}

/// Reads every export back, and checks it holds each export's spans, the first one whole.
fn expect_received(state: *State, round: Round) !void {
    try state.rounds.begin(round.protocols);
    try state.received_call.init(&state.client, {}, &round.options, &.{.{}});
    try state.rounds.request(&state.received_call.call.request, &state.received_call.call.response);
    try state.rounds.finish(round.expected);
    var response = state.received_call.call.read(state.rounds.storage());
    const kept = try response.next(otlp.ExportTraceServiceRequest) orelse return error.CallWrong;
    if (try service.count_spans(&kept) != state.exports * constants.spans_per_export) return error.CallWrong;
    var resources = kept.resource_spans.iterator();
    const resource = try resources.next() orelse return error.CallWrong;
    var scopes = resource.scope_spans.iterator();
    const scope = try scopes.next() orelse return error.CallWrong;
    if (!std.mem.eql(u8, scope.scope.?.name, scope_name)) return error.CallWrong;
    var spans = scope.spans.iterator();
    const first = try spans.next() orelse return error.CallWrong;
    if (!std.mem.eql(u8, first.name, checkout_spans[0].name)) return error.CallWrong;
    if (!std.mem.eql(u8, first.trace_id, &constants.trace_id)) return error.CallWrong;
    if (try first.events.count() != 1 or first.status.?.code != .status_code_ok) return error.CallWrong;
    try harness.expect_end(&response, otlp.ExportTraceServiceRequest);
}

/// The instrumentation scope, as an SDK's tracer names it.
const scope_name = "connect-zig/examples/otlp";

const service_attributes = [_]common.KeyValue{
    .{ .key = "service.name", .value = .{ .value = .{ .string_value = "checkout" } } },
};

const query_attributes = [_]common.KeyValue{
    .{ .key = "db.system", .value = .{ .value = .{ .string_value = "sqlite" } } },
    .{ .key = "db.retries", .value = .{ .value = .{ .int_value = constants.retries } } },
    .{ .key = "db.cached", .value = .{ .value = .{ .bool_value = false } } },
    .{ .key = "db.sample_ratio", .value = .{ .value = .{ .double_value = constants.ratio } } },
};

const checkout_attributes = [_]common.KeyValue{
    .{ .key = "http.request.method", .value = .{ .value = .{ .string_value = "POST" } } },
    .{ .key = "http.response.status_code", .value = .{ .value = .{ .int_value = constants.status_code } } },
};

const checkout_events = [_]trace.Span.Event{
    .{ .time_unix_nano = constants.query_end_ns, .name = "cart loaded" },
};

const checkout_spans = [_]trace.Span{
    .{
        .trace_id = &constants.trace_id,
        .span_id = &constants.checkout_span_id,
        .name = "POST /checkout",
        .kind = .span_kind_server,
        .start_time_unix_nano = constants.start_ns,
        .end_time_unix_nano = constants.end_ns,
        .attributes = .of(&checkout_attributes),
        .events = .of(&checkout_events),
        .status = .{ .code = .status_code_ok },
    },
    .{
        .trace_id = &constants.trace_id,
        .span_id = &constants.query_span_id,
        .parent_span_id = &constants.checkout_span_id,
        .name = "SELECT cart",
        .kind = .span_kind_client,
        .start_time_unix_nano = constants.query_start_ns,
        .end_time_unix_nano = constants.query_end_ns,
        .attributes = .of(&query_attributes),
    },
    .{
        .trace_id = &constants.trace_id,
        .span_id = &constants.charge_span_id,
        .parent_span_id = &constants.checkout_span_id,
        .name = "charge card",
        .kind = .span_kind_client,
        .start_time_unix_nano = constants.charge_start_ns,
        .end_time_unix_nano = constants.charge_end_ns,
        .status = .{ .code = .status_code_error, .message = "card declined" },
    },
};

const checkout_scopes = [_]trace.ScopeSpans{
    .{ .scope = .{ .name = scope_name, .version = "1.0.0" }, .spans = .of(&checkout_spans) },
};

const checkout_resources = [_]trace.ResourceSpans{
    .{ .resource = .{ .attributes = .of(&service_attributes) }, .scope_spans = .of(&checkout_scopes) },
};

/// The export request of the checkout trace.
const checkout: otlp.ExportTraceServiceRequest = .{ .resource_spans = .of(&checkout_resources) };

comptime {
    std.debug.assert(checkout_spans.len == constants.spans_per_export);
}
