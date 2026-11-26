//! The interop client: connect-zig's client calls `interop.v1.InteropService` on a server written
//! in another language, the mirror of interop/'s clients, which call connect-zig's server.
//! `tools/interop_servers_check.sh` starts each server of interop/ and runs this program against
//! it (interop/README.md, "The server side").
//!
//! ```sh
//! interop-client [--leave-out=<protocol>/<scenario>]... <server> <base-url> <cases-dir> <ca> <protocol>...
//! ```
//!
//! Each protocol names a run: `connect-proto`, `connect-json`, `connect-h1`, `grpc`, `grpc-web`
//! or `grpc-web-h1`. A run speaks its protocol and codec over h2, or over h11 for the `-h1` ones,
//! on one `client.ConnectionPool` driven by the conformance client's transport (decision 32), over
//! TLS that trusts the CA in `<ca>` alone when `<base-url>` is https. It runs every scenario of
//! the contract with every case of `<cases-dir>`, and prints `ok: <server> <protocol> <scenario>`
//! or `FAIL: <server> <protocol> <scenario>: <reason>` for each. It exits 1 when any failed.
//! `--leave-out` names a scenario the server's library cannot express, such as chat over h11,
//! which the client neither runs nor prints (interop/README.md).
const std = @import("std");
const connect = @import("connect");
const client = @import("colibri").client;
const tls = @import("colibri").tls;
const proto = @import("protobuf");
/// A check program decodes and encodes with the build target's CPU features: it runs on the
/// machine it was built for, and a library takes the features its program detected.
const protobuf_decoder: proto.Decoder = .init(.target());
const coverage = @import("coverage");
const rpc = @import("connect_colibri");
const transport = @import("client_transport");
const constants = @import("constants.zig");
const scenarios = @import("scenarios.zig");
const Verdict = @import("verdict.zig").Verdict;
const Case = scenarios.Case;
const Run = scenarios.Run;

/// An Any in the cases names coverage types, which JSON reads and writes (decision 21).
pub const protobuf_any_types: []const type = &.{ coverage.Everything, coverage.Nested, coverage.Scalars };

pub const Error = error{ TooManyLeftOut, UsageWrong, NoCases, TooManyCases, CasesTooLarge, BaseUrlWrong, NoAnchor, ProtocolUnknown };

/// A run the client knows: its name, what it speaks, and whether Connect GET applies.
const Protocol = struct {
    name: []const u8,
    protocol: connect.Protocol,
    codec: connect.Codec,
    http: client.Protocol,
};

const known = [_]Protocol{
    .{ .name = "connect-proto", .protocol = .connect, .codec = .proto, .http = .h2 },
    .{ .name = "connect-json", .protocol = .connect, .codec = .json, .http = .h2 },
    .{ .name = "connect-h1", .protocol = .connect, .codec = .proto, .http = .h11 },
    .{ .name = "grpc", .protocol = .grpc, .codec = .proto, .http = .h2 },
    .{ .name = "grpc-web", .protocol = .grpc_web, .codec = .proto, .http = .h2 },
    .{ .name = "grpc-web-h1", .protocol = .grpc_web, .codec = .proto, .http = .h11 },
};

/// The name the test identity's certificate carries, which the client asks for and judges it by
/// (examples/testdata/tls/identity.zig).
const server_name = "localhost";
/// The option that names each scenario a run leaves out.
const leave_out_option = "--leave-out=";

/// All the program holds, which `main` allocates once before the first call (decision 42).
const State = struct {
    case_octets: [constants.cases_bytes]u8,
    case_names: [constants.names_bytes]u8,
    cases: [constants.cases_max]Case,
    ca_pem: [constants.ca_pem_bytes]u8,
    anchor_der: [constants.certificate_bytes]u8,
    anchor_room: [1]tls.Anchor,
    output: [constants.line_bytes]u8,
    left_out: [constants.left_out_max][]const u8,
    /// The client sends gzip when a scenario asks for it, and reads gzip.
    gzip_decoder: connect.GzipDecoder,
    gzip_encoder: connect.GzipEncoder,
    /// What the program's calls share: the CPU features it detects once, and the coders above.
    client: connect.Client,
    /// The pool and its socket, which every run starts afresh.
    transport: transport.Transport,
    /// The memory of the one call at a time, which every scenario uses.
    room: scenarios.Room,
};

/// What the program reports to: stdout, and the server's name.
const Reporter = struct {
    writer: *std.Io.Writer,
    server: []const u8,
    failures: u32 = 0,
    /// Each `<protocol>/<scenario>` the server's library cannot express.
    left_out: []const []const u8,
    /// The reason the last failed scenario recorded.
    verdict: *const Verdict,

    /// Whether the run of `protocol` runs `scenario`.
    fn runs(reporter: *const Reporter, protocol: []const u8, scenario: []const u8) bool {
        for (reporter.left_out) |each| {
            const slash = std.mem.indexOfScalar(u8, each, '/') orelse continue;
            if (std.mem.eql(u8, each[0..slash], protocol) and std.mem.eql(u8, each[slash + 1 ..], scenario)) return false;
        }
        return true;
    }

    fn report(reporter: *Reporter, protocol: []const u8, scenario: []const u8, case: []const u8, outcome: Verdict.Error!void) void {
        const separator = if (case.len == 0) "" else " ";
        if (outcome) |_| {
            reporter.writer.print("ok: {s} {s} {s}{s}{s}\n", .{ reporter.server, protocol, scenario, separator, case }) catch {};
        } else |_| {
            reporter.failures += 1;
            reporter.writer.print("FAIL: {s} {s} {s}{s}{s}: {s}\n", .{ reporter.server, protocol, scenario, separator, case, reporter.verdict.reason() }) catch {};
        }
        reporter.writer.flush() catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    state.room.verdict = .{};
    state.client = .{ .cpu_features = .detect(), .encoders = .{ .gzip = &state.gzip_encoder }, .decoders = .{ .gzip = &state.gzip_decoder } };
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const left = try read_left_out(state, &args);
    const base_url = args.next() orelse return error.UsageWrong;
    const read = try read_cases(state, io, args.next() orelse return error.UsageWrong);
    const origin = try Origin.parse(base_url);
    const ca_path = args.next() orelse return error.UsageWrong;
    // Over TLS the client trusts the CA alone; in cleartext it names none.
    // The transport holds the one `stdx.crypto` context, which the TLS value takes: it states no
    // CPU feature, so each TLS session runs chapulin's portable code.
    state.transport.init(io);
    const trust: ?tls.Client = if (origin.secure) try trust_of(state, io, ca_path) else null;
    var stdout = std.Io.File.stdout().writerStreaming(io, &state.output);
    var reporter: Reporter = .{ .writer = &stdout.interface, .server = left.server, .left_out = left.left_out, .verdict = &state.room.verdict };
    for (0..known.len + 1) |_| {
        const name = args.next() orelse break;
        try run_all(state, &reporter, try protocol_named(name), &origin, trust, read);
    }
    if (reporter.failures > 0) std.process.exit(1);
}

/// Reads each `--leave-out=` option, then the server's name.
fn read_left_out(state: *State, args: anytype) Error!struct { server: []const u8, left_out: []const []const u8 } {
    const left_out = &state.left_out;
    for (0..constants.left_out_max + 1) |count| {
        const arg = args.next() orelse return error.UsageWrong;
        if (!std.mem.startsWith(u8, arg, leave_out_option)) return .{ .server = arg, .left_out = left_out[0..count] };
        if (count == constants.left_out_max) return error.TooManyLeftOut;
        left_out[count] = arg[leave_out_option.len..];
    }
    return error.TooManyLeftOut;
}

fn protocol_named(name: []const u8) Error!*const Protocol {
    for (&known) |*each| {
        if (std.mem.eql(u8, each.name, name)) return each;
    }
    return error.ProtocolUnknown;
}

/// The server's origin: its IP literal, its port, and whether it speaks TLS.
const Origin = struct {
    host: []const u8,
    port: u16,
    secure: bool,

    fn parse(url: []const u8) Error!Origin {
        const secure = std.mem.startsWith(u8, url, "https://");
        if (!secure and !std.mem.startsWith(u8, url, "http://")) return error.BaseUrlWrong;
        const authority = url[(std.mem.indexOf(u8, url, "://") orelse unreachable) + "://".len ..];
        const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return error.BaseUrlWrong;
        const port = std.fmt.parseInt(u16, authority[colon + 1 ..], constants.decimal) catch return error.BaseUrlWrong;
        // RFC 3986 §3.2.2: an IPv6 literal goes in brackets.
        const host = std.mem.trim(u8, authority[0..colon], "[]");
        return .{ .host = host, .port = port, .secure = secure };
    }
};

/// The TLS the client speaks: it trusts the CA in the PEM file at `path`, and no other.
fn trust_of(state: *State, io: std.Io, path: []const u8) !tls.Client {
    const pem = try std.Io.Dir.cwd().readFile(io, path, &state.ca_pem);
    const anchors = try tls.pem.anchors(pem, &state.anchor_der, &state.anchor_room);
    if (anchors.len == 0) return error.NoAnchor;
    return .{ .trust = .{ .web_pki = .{ .anchors = anchors, .server_name = server_name } }, .crypto = state.transport.crypto };
}

/// Reads each `<name>.binpb` of `path`, a `coverage.v1.Everything`, in the order of their names.
fn read_cases(state: *State, io: std.Io, path: []const u8) ![]const Case {
    const case_names = &state.case_names;
    const case_octets = &state.case_octets;
    const cases = &state.cases;
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var entries = directory.iterate();
    var count: usize = 0;
    var octets_used: usize = 0;
    var names_used: usize = 0;
    for (0..constants.cases_max + 1) |_| {
        const entry = try entries.next(io) orelse break;
        if (!std.mem.endsWith(u8, entry.name, ".binpb")) continue;
        if (count == constants.cases_max) return error.TooManyCases;
        const name = entry.name[0 .. entry.name.len - ".binpb".len];
        if (name.len > case_names.len - names_used) return error.CasesTooLarge;
        @memcpy(case_names[names_used..][0..name.len], name);
        const octets = directory.readFile(io, entry.name, case_octets[octets_used..]) catch return error.CasesTooLarge;
        cases[count] = .{ .name = case_names[names_used..][0..name.len], .message = try protobuf_decoder.decode(coverage.Everything, octets) };
        names_used += name.len;
        octets_used += octets.len;
        count += 1;
    }
    if (count == 0) return error.NoCases;
    std.mem.sort(Case, cases[0..count], {}, by_name);
    return cases[0..count];
}

fn by_name(_: void, left: Case, right: Case) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

/// Runs every scenario of one protocol on one pool, which speaks the run's HTTP version alone.
fn run_all(state: *State, reporter: *Reporter, protocol: *const Protocol, origin: *const Origin, trust: ?tls.Client, all: []const Case) !void {
    const versions: client.Protocols = switch (protocol.http) {
        .h2 => .{ .h11 = false, .h2 = true, .h3 = false },
        .h11 => .{ .h11 = true, .h2 = false, .h3 = false },
        .h3 => unreachable,
    };
    try state.transport.begin(origin.host, origin.port, versions, trust, state.client.cpu_features);
    defer state.transport.end();
    const run: Run = .{
        .client = &state.client,
        .options = .{ .protocol = protocol.protocol, .codec = protocol.codec },
        .full_duplex = rpc.full_duplex(protocol.http),
        .transport = &state.transport,
        .room = &state.room,
    };
    run_cases(reporter, protocol, &run, all);
    run_calls(reporter, protocol.name, &run, all);
}

/// The scenarios run once for each case: the echoes.
fn run_cases(reporter: *Reporter, protocol: *const Protocol, run: *const Run, all: []const Case) void {
    const name = protocol.name;
    if (reporter.runs(name, "echo")) {
        for (all) |*case| reporter.report(name, "echo", case.name, scenarios.echo(run, case, .identity, false));
    }
    if (reporter.runs(name, "echo-gzip")) {
        for (all) |*case| reporter.report(name, "echo-gzip", case.name, scenarios.echo(run, case, .gzip, false));
    }
    // Connect protocol, "Unary-Get-Request": GET is Connect's alone.
    if (protocol.protocol == .connect and reporter.runs(name, "echo-get")) {
        for (all) |*case| reporter.report(name, "echo-get", case.name, scenarios.echo(run, case, .identity, true));
    }
}

/// The scenarios run once: each stream shape, a typed error, a timeout, headers and trailers.
fn run_calls(reporter: *Reporter, name: []const u8, run: *const Run, all: []const Case) void {
    if (reporter.runs(name, "repeat")) reporter.report(name, "repeat", "", scenarios.repeat(run, &all[all.len - 1]));
    if (reporter.runs(name, "collect")) reporter.report(name, "collect", "", scenarios.collect(run, all));
    if (reporter.runs(name, "chat")) reporter.report(name, "chat", "", scenarios.chat(run, all));
    if (reporter.runs(name, "fail")) reporter.report(name, "fail", "", scenarios.fail(run));
    if (reporter.runs(name, "inspect")) reporter.report(name, "inspect", "", scenarios.inspect(run));
}

test {
    _ = @import("same.zig");
    // The tests reach no colibri type, yet the binary links chapulin's objects through stdx.
    // Naming colibri reads its root, which reads stdx's, and stdx's root keeps chapulin's hook,
    // `ch_assert_fail`, beside them (decision 34 as amended).
    _ = client;
}
