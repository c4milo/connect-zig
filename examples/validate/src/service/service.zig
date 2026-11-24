//! The signup service, signup.v1.SignupService, behind `protovalidate.Interceptor` (decision
//! 47). signup.proto states each field's rules, the plugin writes them beside the message, and
//! the interceptor checks each request message against them before a handler takes it.
//!
//! - A program's route table names `Values` as its `.Values`: what each call keeps for itself.
//! - A program's `App` holds the service's `Room` in its field `signup`, so one route table may
//!   serve the service beside others (decision 41).
//!
//! A message that breaks a rule ends its call with `invalid_argument`. The error's message names
//! the first violation, and its detail is a `buf.validate.Violations` that holds each one.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect_zig").connect;
const rpc = @import("connect_zig").connect_colibri;
const protovalidate = @import("connect_zig").protovalidate;
const signup = @import("signup");
const constants = @import("constants.zig");
const SignupService = signup.SignupService;

/// The interceptor's sizes: room for about 16 violations of a message.
const validation: protovalidate.InterceptorOptions = .{};

/// What each call keeps for itself (decision 35): what the error of a refused message points
/// to, until the reply is written. `protovalidate.Interceptor` reads it by this name.
pub const Values = struct {
    protovalidate: protovalidate.InterceptorRoom(connect, validation) = .{},
};

/// Checks each request message of the service. It takes the `connect` module the program builds
/// with, since `protovalidate` imports none.
const Validate = protovalidate.Interceptor(connect, Values, validation);

/// The route options of each method: room for a message and a JSON token of the longest text,
/// and `Validate` around the handler.
pub const route_options: rpc.RouteOptions = .{
    .message_bytes = constants.message_len_max,
    .token_bytes = constants.message_len_max,
    .interceptors = &.{Validate},
};

/// The service's part of a program's `App`: the accounts its handlers took, which goes on
/// across calls.
pub const Room = struct {
    accepted: u32 = 0,
};

/// The service's handlers over `App`, and their entries in a route table: `Service(App).routes`.
/// Each handler passes the call to the function below of the same name.
pub fn Service(comptime App: type) type {
    return struct {
        pub const routes = SignupService.Routes(rpc, App, @This(), route_options).routes;

        pub fn register(app: *App, _: *rpc.Context, request: *const rpc.Request(signup.RegisterRequest), response: *rpc.Response(signup.RegisterResponse)) ?connect.RpcError {
            return register_in(&app.signup, request, response);
        }

        pub fn register_many(app: *App, _: *rpc.Context, request: *rpc.RequestStream(signup.RegisterRequest), response: *rpc.Response(signup.RegisterManyResponse)) ?connect.RpcError {
            return register_many_in(&app.signup, request, response);
        }
    };
}

/// Takes one account. The interceptor checked the message, so the handler reads it as its
/// schema states it.
fn register_in(room: *Room, request: *const rpc.Request(signup.RegisterRequest), response: *rpc.Response(signup.RegisterResponse)) ?connect.RpcError {
    take(room, &request.message);
    response.message.name = request.message.name;
    return null;
}

/// Takes each account of the stream. The interceptor checks each message as the handler asks for
/// it: one that breaks a rule ends the stream, and the call then fails with the interceptor's
/// error, whatever the handler answers.
fn register_many_in(room: *Room, request: *rpc.RequestStream(signup.RegisterRequest), response: *rpc.Response(signup.RegisterManyResponse)) ?connect.RpcError {
    for (0..constants.accounts_per_call_max) |_| {
        const account = request.next() orelse return null;
        take(room, &account);
        response.message.accepted += 1;
    }
    return .{ .code = .resource_exhausted, .message = "too many accounts in one call" };
}

fn take(room: *Room, account: *const signup.RegisterRequest) void {
    // signup.proto: `name` has at least one character, and `age` is 13 or more.
    assert(account.name.len != 0);
    assert(account.age >= signup.RegisterRequest.RuleNumber.@"age.int32.gte");
    room.accepted += 1;
}
