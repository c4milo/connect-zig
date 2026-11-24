//! The scenarios of interop/README.md, as connect-zig's client runs them against a server in
//! another language: each takes the run's options and the coverage cases, and returns nothing
//! when the server answered as the contract says, or `error.Wrong` with the reason.
const std = @import("std");
const connect = @import("connect");
const proto = @import("protobuf");
/// A check program decodes and encodes with the build target's CPU features: it runs on the
/// machine it was built for, and a library takes the features its program detected.
const protobuf_decoder: proto.Decoder = .init(.target());
const coverage = @import("coverage");
const interop = @import("interop");
const constants = @import("constants.zig");
const exchange = @import("exchange.zig");
const same = @import("same.zig");
const Buffers = @import("buffers.zig").Buffers;
const Verdict = @import("verdict.zig").Verdict;
const Transport = @import("client_transport").Transport;
const Exchange = exchange.Exchange;
const Unwatched = exchange.Unwatched;
const Service = interop.InteropService;
const Error = Verdict.Error;

/// A case of examples/testdata/coverage: its name and its message.
pub const Case = struct {
    name: []const u8,
    message: coverage.Everything,
};

/// What a run of the scenarios speaks: the call options of its protocol and codec, and whether
/// its streams are full-duplex. Its calls run on `transport`, in `room`.
pub const Run = struct {
    options: connect.client.Options,
    full_duplex: bool,
    transport: *Transport,
    room: *Room,
};

/// The exchange of each scenario's call. One call runs at a time, so they share one place in the
/// `Room`.
pub const Exchanges = union(enum) {
    echo: Exchange(Service.echo, Unwatched),
    echo_get: Exchange(Service.echo_get, Unwatched),
    repeat: Exchange(Service.repeat, Unwatched),
    collect: Exchange(Service.collect, Unwatched),
    chat: Exchange(Service.chat, ChatWatcher),
    fail: Exchange(Service.fail, Unwatched),
    inspect: Exchange(Service.inspect, Unwatched),
};
/// The method of a call, which names its exchange.
const Kind = std.meta.Tag(Exchanges);

/// The memory of the one call at a time, which every scenario uses: the client runs one call to
/// its end before it starts the next. `main` keeps it in its `State` (decision 42).
pub const Room = struct {
    buffers: Buffers,
    comparison: same.Comparison,
    /// The reason the last failed scenario recorded.
    verdict: Verdict,
    /// The exchange of the call that runs. colibri reads and writes it until it finished, so it
    /// lives outside the stack.
    exchanges: Exchanges,
};

/// The code and message `fail` asks for: not_found (statuscodes.md).
const fail_code = @intFromEnum(connect.Code.not_found);
const fail_message = "gone";
/// The header `inspect` sends, and expects back as a header and a trailer.
pub const client_header = "x-interop-client";
pub const client_name = "zig";
/// Connect protocol, "Unary-Response": a unary response's trailers are headers with this prefix.
const connect_trailer_prefix = "trailer-";

fn numbers_of(run: *const Run) same.Numbers {
    return if (run.options.codec == .json) .by_value else .by_text;
}

/// Fails unless the answer `got` is the same message as the case `want`.
fn expect_same(run: *const Run, want: *const coverage.Everything, got: *const coverage.Everything) Error!void {
    return same.expect(coverage.Everything, &run.room.comparison, &run.room.verdict, want, got, numbers_of(run));
}

/// Reads the first message of a response. It stays valid until the next `next`, which may
/// inflate the end of the response into the same scratch, so the caller checks it first.
fn first(comptime T: type, verdict: *Verdict, response: *connect.client.Response) Error!T {
    const message = response.next(T) catch |failure| return verdict.failed(connect.client.failure_of(failure));
    return message orelse verdict.failed(response.failure orelse return verdict.wrong("no message", .{}));
}

/// Checks a response holds no message more, and ended in success.
fn expect_end(verdict: *Verdict, response: *connect.client.Response) Error!void {
    const extra = response.next(coverage.Everything) catch |failure| return verdict.failed(connect.client.failure_of(failure));
    if (extra != null) return verdict.wrong("a message after the last", .{});
    if (response.failure) |failure| return verdict.failed(failure);
}

/// `Echo`, or `EchoGet` as a GET, of one case answers with the same message, with the request
/// compressed by `coding` when it shrinks.
pub fn echo(run: *const Run, case: *const Case, coding: connect.Coding, use_get: bool) Error!void {
    var options = run.options;
    options.request_coding = coding;
    options.use_get = use_get;
    if (use_get) return echo_with(.echo_get, run, &options, case);
    return echo_with(.echo, run, &options, case);
}

fn echo_with(comptime kind: Kind, run: *const Run, options: *const connect.client.Options, case: *const Case) Error!void {
    const verdict = &run.room.verdict;
    var watcher: Unwatched = .{};
    const call = try begin(kind, run, options, &.{case.message}, &watcher);
    var response = try exchange.finish(call);
    const answer = try first(coverage.Everything, verdict, &response);
    try expect_same(run, &case.message, &answer);
    try expect_end(verdict, &response);
}

/// The exchange of a call of `kind`.
fn ExchangeOf(comptime kind: Kind) type {
    return @FieldType(Exchanges, @tagName(kind));
}

/// Starts the call of `kind` in the run's room, where it replaces the call before it.
fn begin(comptime kind: Kind, run: *const Run, options: *const connect.client.Options, messages: []const ExchangeOf(kind).rpc_method.Request, watcher: anytype) Error!*ExchangeOf(kind) {
    const room = run.room;
    room.exchanges = @unionInit(Exchanges, @tagName(kind), undefined);
    const call = &@field(room.exchanges, @tagName(kind));
    const shared: exchange.Shared = .{ .transport = run.transport, .buffers = &room.buffers, .verdict = &room.verdict };
    call.begin(shared, options, messages, watcher) catch |failure|
        return room.verdict.wrong("starting the call: {s}", .{@errorName(failure)});
    return call;
}

/// `Repeat` of one case, three times, answers with three copies.
pub fn repeat(run: *const Run, case: *const Case) Error!void {
    const verdict = &run.room.verdict;
    var watcher: Unwatched = .{};
    const request: interop.RepeatRequest = .{ .message = case.message, .count = constants.repeat_count };
    const call = try begin(.repeat, run, &run.options, &.{request}, &watcher);
    var response = try exchange.finish(call);
    for (0..constants.repeat_count) |index| {
        const message = response.next(coverage.Everything) catch |failure| return verdict.failed(connect.client.failure_of(failure));
        const answer = message orelse {
            if (response.failure) |failure| return verdict.failed(failure);
            return verdict.wrong("got {d} messages, wanted {d}", .{ index, constants.repeat_count });
        };
        try expect_same(run, &case.message, &answer);
    }
    try expect_end(verdict, &response);
}

/// `Collect` of every case answers with their count and the last case.
pub fn collect(run: *const Run, cases: []const Case) Error!void {
    const verdict = &run.room.verdict;
    var watcher: Unwatched = .{};
    const call = try begin(.collect, run, &run.options, &.{}, &watcher);
    for (cases) |*case| try exchange.send(call, &case.message);
    try exchange.close_send(call);
    var response = try exchange.finish(call);
    const answer = try first(interop.CollectResponse, verdict, &response);
    if (answer.count != cases.len) return verdict.wrong("counted {d}, sent {d}", .{ answer.count, cases.len });
    const last = answer.last orelse return verdict.wrong("no last message", .{});
    try expect_same(run, &cases[cases.len - 1].message, &last);
    try expect_end(verdict, &response);
}

/// Checks each answer of `Chat` against the case sent in its place, as it arrives.
const ChatWatcher = struct {
    run: *const Run,
    cases: []const Case,
    answers: u32 = 0,
    /// The first answer that differed, or that came beyond the cases.
    mismatch: ?u32 = null,

    pub fn on_answer(watcher: *ChatWatcher, answer: *const coverage.Everything) void {
        defer watcher.answers += 1;
        if (watcher.mismatch != null) return;
        if (watcher.answers >= watcher.cases.len) {
            watcher.mismatch = watcher.answers;
            return;
        }
        expect_same(watcher.run, &watcher.cases[watcher.answers].message, answer) catch {
            watcher.mismatch = watcher.answers;
        };
    }
};

/// `Chat` answers each case. Full-duplex, each answer arrives before the client sends the next
/// case; half-duplex, over h11, every case goes first (decision 18 as amended).
pub fn chat(run: *const Run, cases: []const Case) Error!void {
    const verdict = &run.room.verdict;
    var watcher: ChatWatcher = .{ .run = run, .cases = cases };
    const call = try begin(.chat, run, &run.options, &.{}, &watcher);
    for (cases, 0..) |*case, index| {
        try exchange.send(call, &case.message);
        if (run.full_duplex) try exchange.wait_answers(call, @intCast(index + 1));
    }
    try exchange.close_send(call);
    var response = try exchange.finish(call);
    // The answers the response holds past those read as they arrived.
    for (0..cases.len + 1) |_| {
        const message = response.next(coverage.Everything) catch |failure| return verdict.failed(connect.client.failure_of(failure));
        watcher.on_answer(&(message orelse break));
    }
    if (response.failure) |failure| return verdict.failed(failure);
    if (watcher.mismatch) |index| {
        if (index >= cases.len) return verdict.wrong("more answers than the {d} cases", .{cases.len});
        // The comparison recorded why the answer differs, and no check since wrote a reason.
        return error.Wrong;
    }
    if (watcher.answers != cases.len) return verdict.wrong("got {d} answers, wanted {d}", .{ watcher.answers, cases.len });
}

/// `Fail` with code 5 and message "gone" fails with not_found, "gone", and one detail that holds
/// the request.
pub fn fail(run: *const Run) Error!void {
    const verdict = &run.room.verdict;
    var watcher: Unwatched = .{};
    const request: interop.FailRequest = .{ .code = fail_code, .message = fail_message };
    const call = try begin(.fail, run, &run.options, &.{request}, &watcher);
    var response = try exchange.finish(call);
    const message = response.next(coverage.Everything) catch |failure| return verdict.failed(connect.client.failure_of(failure));
    if (message != null) return verdict.wrong("the call succeeded", .{});
    const failure = response.failure orelse return verdict.wrong("the call succeeded with no message", .{});
    if (failure.code != .not_found or !std.mem.eql(u8, failure.message, fail_message)) return verdict.failed(failure);
    if (failure.details.len != 1) return verdict.wrong("got {d} details, wanted 1", .{failure.details.len});
    const detail = failure.details[0];
    if (!std.mem.eql(u8, detail.type_name, interop.FailRequest.protobuf.full_name)) return verdict.wrong("the detail is a {s}", .{detail.type_name});
    const decoded = protobuf_decoder.decode(interop.FailRequest, detail.value) catch return verdict.wrong("the detail does not decode", .{});
    if (decoded.code != fail_code or !std.mem.eql(u8, decoded.message, fail_message)) {
        return verdict.wrong("the detail holds code {d} and message \"{s}\"", .{ decoded.code, decoded.message });
    }
}

/// `Inspect` with a 5 s timeout and the header `x-interop-client: zig` answers with the timeout
/// and the header, and sends the header back as a response header and as a trailer.
pub fn inspect(run: *const Run) Error!void {
    const verdict = &run.room.verdict;
    var options = run.options;
    options.timeout_ns = constants.inspect_timeout_ns;
    const headers = [_]connect.Header{.{ .name = client_header, .value = client_name }};
    options.headers = &headers;
    var watcher: Unwatched = .{};
    const call = try begin(.inspect, run, &options, &.{.{}}, &watcher);
    var response = try exchange.finish(call);
    const answer = try first(interop.InspectResponse, verdict, &response);
    if (answer.timeout_ms < 1 or answer.timeout_ms > constants.inspect_timeout_ms_max) return verdict.wrong("the server saw a timeout of {d} ms", .{answer.timeout_ms});
    try expect_line(verdict, &answer);
    try expect_end(verdict, &response);
    const sent_back = exchange.header(call, client_header) orelse "";
    if (!std.mem.eql(u8, sent_back, client_name)) return verdict.wrong("the response header {s} is \"{s}\"", .{ client_header, sent_back });
    const trailer = trailer_of(run.options.protocol, call, &response) orelse "";
    if (!std.mem.eql(u8, trailer, client_name)) return verdict.wrong("the trailer {s} is \"{s}\"", .{ client_header, trailer });
}

/// The server's list of the headers it saw holds the client's.
fn expect_line(verdict: *Verdict, answer: *const interop.InspectResponse) Error!void {
    const line = client_header ++ ": " ++ client_name;
    const count = answer.headers.count() catch return verdict.wrong("the headers seen do not decode", .{});
    var lines = answer.headers.iterator();
    for (0..count) |_| {
        const seen = (lines.next() catch break) orelse break;
        if (std.ascii.eqlIgnoreCase(seen, line)) return;
    }
    return verdict.wrong("the server saw {d} x-interop headers, none of them the client's", .{count});
}

/// The trailer the server sent back, where its protocol puts it.
fn trailer_of(protocol: connect.Protocol, call: anytype, response: *const connect.client.Response) ?[]const u8 {
    return switch (protocol) {
        // PROTOCOL-HTTP2.md, "Responses": gRPC's trailers are HTTP trailers.
        .grpc => exchange.trailer(call, client_header),
        // Connect protocol, "Unary-Response": a trailer is a header named "trailer-" and its name.
        .connect => exchange.header(call, connect_trailer_prefix ++ client_header),
        // PROTOCOL-WEB.md: gRPC-Web's trailers come in the body's trailers frame.
        .grpc_web => find(response.metadata, client_header),
    };
}

fn find(lines: []const connect.Header, name: []const u8) ?[]const u8 {
    for (lines) |line| {
        if (std.ascii.eqlIgnoreCase(line.name, name)) return line.value;
    }
    return null;
}
