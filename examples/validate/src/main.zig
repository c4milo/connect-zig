//! Example: a server that validates each request message against the rules of its schema.
//!
//! signup.proto states the rules of `RegisterRequest` with protovalidate's options. The plugin
//! writes them beside the message, and `protovalidate.Interceptor`, in the service's route
//! options, checks each request message before its handler takes it (decision 47).
//!
//! Three rounds run, over h2, h11 and h3. In each:
//!
//! - an account that keeps the rules is taken, over Connect;
//! - an account with a wrong email is refused, over Connect in JSON, with one violation;
//! - an account that breaks three rules is refused, over gRPC, with three violations;
//! - a stream of two accounts is taken, over gRPC-Web;
//! - a stream whose second account breaks a rule is refused there, and its third is never read.
//!
//! The client reads each refusal's `buf.validate.Violations` from the error's detail. Run it with
//! `zig build run`.
const std = @import("std");
const proto = @import("connect_zig").protobuf;
const connect = @import("connect_zig").connect;
const client = @import("connect_zig").colibri.client;
const harness = @import("harness");
const pb = @import("connect_zig").buf_validate_validate;
const signup = @import("signup");
const constants = @import("constants.zig");
const app_file = @import("app.zig");
const App = app_file.App;
const Router = app_file.Router;
const SignupService = signup.SignupService;

comptime {
    _ = harness.hooks;
}

pub const Error = error{CallWrong};

const RegisterCall = harness.Call(SignupService.register, .{});
const RegisterManyCall = harness.Call(SignupService.register_many, .{});

const ada: signup.RegisterRequest = .{ .email = "ada@example.com", .name = "Ada", .age = constants.age_ada, .tags = .of(&.{ "math", "engines" }) };
const grace: signup.RegisterRequest = .{ .email = "grace@example.com", .name = "Grace", .age = constants.age_grace };
/// An email with no "@".
const wrong_email: signup.RegisterRequest = .{ .email = "ada.example.com", .name = "Ada", .age = constants.age_ada };
/// No name, an age under 13, and a tag twice.
const three_wrong: signup.RegisterRequest = .{ .email = "kid@example.com", .name = "", .age = constants.age_too_young, .tags = .of(&.{ "a", "a" }) };

/// All the program holds, which `main` allocates once (decision 42). colibri reads and writes
/// each call until its round ends, so the calls live here.
const State = struct {
    app: App,
    /// What the program's calls share: the CPU features it detected (decision 51).
    client: connect.Client,
    /// Decodes the detail of an error, with the CPU features the program detected once.
    protobuf_decoder: proto.Decoder,
    rounds: harness.Rounds(App, Router),
    valid: RegisterCall,
    email: RegisterCall,
    three: RegisterCall,
    many: RegisterManyCall,
    many_cut: RegisterManyCall,
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    state.app = .{ .cpu_features = .detect() };
    // One client for every call, with the CPU features the program detected.
    state.client = .{ .cpu_features = state.app.cpu_features };
    state.protobuf_decoder = .init(state.app.cpu_features);
    try state.rounds.init(&state.app);
    defer state.rounds.deinit();
    try round(state, .{ .h11 = false, .h3 = false }, .h2);
    try round(state, .{ .h2 = false, .h3 = false }, .h11);
    try round(state, .{ .h11 = false, .h2 = false }, .h3);
    std.debug.print("validate: every call answered as expected over h2, h11 and h3\n", .{});
}

/// Runs the five calls over `expected`. The server's count goes on across rounds, so the round
/// checks what it added to it.
fn round(state: *State, protocols: client.Protocols, expected: client.Protocol) !void {
    const accepted_before = state.app.signup.accepted;
    const rounds = &state.rounds;
    try rounds.begin(protocols);
    try state.valid.init(&state.client, {}, &.{}, &.{ada});
    try state.email.init(&state.client, {}, &.{ .codec = .json }, &.{wrong_email});
    try state.three.init(&state.client, {}, &.{ .protocol = .grpc }, &.{three_wrong});
    try state.many.init(&state.client, {}, &.{ .protocol = .grpc_web }, &.{ ada, grace });
    try state.many_cut.init(&state.client, {}, &.{}, &.{ ada, wrong_email, grace });
    inline for (.{ "valid", "email", "three", "many", "many_cut" }) |field| {
        const call = &@field(state, field).call;
        try rounds.request(&call.request, &call.response);
    }
    try rounds.finish(expected);

    try expect_taken(state);
    try expect_refused(state, &state.email, signup.RegisterResponse, &.{"string.email"});
    try expect_refused(state, &state.three, signup.RegisterResponse, &.{ "string.min_len", "int32.gte_lt", "repeated.unique" });
    try expect_count(state);
    try expect_refused(state, &state.many_cut, signup.RegisterManyResponse, &.{"string.email"});
    // The handlers took the one account, the stream of two, and the first of the stream that
    // was cut: no handler took a message that broke a rule, or one after it.
    const taken = state.app.signup.accepted - accepted_before;
    const accounts_taken = 4;
    if (taken != accounts_taken) return error.CallWrong;
    std.debug.print("validate: over {s}, the handlers took {d} accounts, and no account that broke a rule\n", .{ @tagName(expected), taken });
}

fn expect_taken(state: *State) !void {
    var response = state.valid.call.read(state.rounds.storage());
    const answer = try response.next(signup.RegisterResponse) orelse return error.CallWrong;
    if (!std.mem.eql(u8, answer.name, ada.name)) return error.CallWrong;
    try harness.expect_end(&response, signup.RegisterResponse);
    std.debug.print("validate: register took {s}\n", .{answer.name});
}

fn expect_count(state: *State) !void {
    var response = state.many.call.read(state.rounds.storage());
    const answer = try response.next(signup.RegisterManyResponse) orelse return error.CallWrong;
    const accounts_sent = 2;
    if (answer.accepted != accounts_sent) return error.CallWrong;
    try harness.expect_end(&response, signup.RegisterManyResponse);
    std.debug.print("validate: register of a stream took {d} accounts\n", .{answer.accepted});
}

/// Checks a call failed with `invalid_argument` and one detail, a `buf.validate.Violations`
/// whose violations broke the rules `rule_ids` name, in order.
fn expect_refused(state: *State, call: anytype, comptime Answer: type, rule_ids: []const []const u8) !void {
    var response = call.call.read(state.rounds.storage());
    if (try response.next(Answer) != null) return error.CallWrong;
    const failure = response.failure orelse return error.CallWrong;
    if (failure.code != .invalid_argument or failure.details.len != 1) return error.CallWrong;
    const detail = failure.details[0];
    // A detail names its message type, so a client decodes only the details it knows.
    if (!std.mem.eql(u8, detail.type_name, pb.Violations.protobuf.full_name)) return error.CallWrong;
    std.debug.print("validate: refused: {s}: {s}\n", .{ failure.code.name(), failure.message });
    const decoded = try state.protobuf_decoder.decode(pb.Violations, detail.value);
    var violations = decoded.violations.iterator();
    for (rule_ids) |rule_id| {
        const violation = try violations.next() orelse return error.CallWrong;
        if (!std.mem.eql(u8, violation.rule_id orelse "", rule_id)) return error.CallWrong;
        try print_violation(violation);
    }
    if (try violations.next() != null) return error.CallWrong;
}

/// Prints one violation: its field, the rule's id and the message.
fn print_violation(violation: *const pb.Violation) !void {
    const path = violation.field orelse return error.CallWrong;
    var elements = path.elements.iterator();
    const field = try elements.next() orelse return error.CallWrong;
    std.debug.print("validate:   {s}: {s} [{s}]\n", .{ field.field_name orelse "", violation.message orelse "", violation.rule_id.? });
}
