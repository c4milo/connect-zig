//! The GitHub-style service of `proto/github/v1/github.proto`: RepositoryService in
//! `repositories.zig` and IssueService in `issues.zig`, over the store of `store.zig`. A
//! program's `App` holds the service's `Room` in its field `github`, so one route table may
//! serve these services beside other services (decision 41).
//!
//! Every route runs behind two interceptors:
//!
//! - `Auth(App, required)` reads "authorization: Bearer <token>". A token the store does not know
//!   fails with unauthenticated, on every route. A route that changes data needs a token.
//! - `RateLimit(App)` counts each caller's calls, anonymous callers together. It adds GitHub's
//!   x-ratelimit-limit and x-ratelimit-remaining headers, and fails with resource_exhausted and
//!   a `RateLimited` detail once the caller used its limit.
//!
//! A read takes a token or none, and a change needs one. Each read with no side effects is
//! served as a GET too.
const std = @import("std");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const github = @import("github");
const store_file = @import("store.zig");
const room_file = @import("room.zig");
const repositories = @import("repositories.zig");
const issues = @import("issues.zig");
const constants = @import("constants.zig");
const Repositories = github.RepositoryService;
const Issues = github.IssueService;

pub const Room = room_file.Room;

/// What a client of the fixed store knows: each user's token, the instant before the store's
/// first change, the rate limit's index of anonymous callers, and their limit.
pub const tokens = store_file.tokens;
pub const epoch_seconds = constants.epoch_seconds;
pub const anonymous = store_file.anonymous;
pub const limit_anonymous = constants.limit_anonymous;

/// The decimal text of each count up to `limit_user`. `Call.add_header` keeps the value's slice
/// until the head goes out, so each value lives as long as the program.
const decimals = table: {
    @setEvalBranchQuota(constants.decimals_branch_quota);
    var table: [constants.limit_user + 1][]const u8 = undefined;
    for (&table, 0..) |*text, count| text.* = std.fmt.comptimePrint("{d}", .{count});
    break :table table;
};

/// Refuses a token the store does not know, and a call with no token when `required`.
pub fn Auth(comptime App: type, comptime required: bool) type {
    return struct {
        pub fn on_call(_: *App, _: *rpc.Context, request: *const rpc.AnyRequest, _: *rpc.AnyResponse) ?connect.RpcError {
            return authenticate(required, request);
        }
    };
}

/// Counts each caller's calls in `app.github`, and refuses one past its limit.
pub fn RateLimit(comptime App: type) type {
    return struct {
        pub fn on_call(app: *App, _: *rpc.Context, request: *const rpc.AnyRequest, response: *rpc.AnyResponse) ?connect.RpcError {
            return count_call(&app.github, request, response);
        }
    };
}

fn authenticate(required: bool, request: *const rpc.AnyRequest) ?connect.RpcError {
    const header = request.header("authorization") orelse {
        if (required) return .{ .code = .unauthenticated, .message = "Requires authentication" };
        return null;
    };
    _ = store_file.user_of(header) orelse return .{ .code = .unauthenticated, .message = "Bad credentials" };
    return null;
}

fn count_call(room: *Room, request: *const rpc.AnyRequest, response: *rpc.AnyResponse) ?connect.RpcError {
    const who: usize = if (room_file.caller(request)) |user| user + 1 else store_file.anonymous;
    const limit: u32 = if (who == store_file.anonymous) constants.limit_anonymous else constants.limit_user;
    const used = room.store.calls[who];
    response.add_header("x-ratelimit-limit", decimals[limit]) catch {};
    if (used >= limit) {
        response.add_header("x-ratelimit-remaining", decimals[0]) catch {};
        const detail: github.RateLimited = .{ .limit = @intCast(limit), .used = @intCast(used) };
        return room_file.detailed(room, .resource_exhausted, "API rate limit exceeded", github.RateLimited, &detail);
    }
    room.store.calls[who] = used + 1;
    response.add_header("x-ratelimit-remaining", decimals[limit - used - 1]) catch {};
    return null;
}

/// The route options of a read or of a change: room for the longest message and JSON token, and
/// the interceptors of the route.
fn options_with(comptime interceptors: []const type) rpc.RouteOptions {
    return .{ .message_bytes = constants.message_bytes, .token_bytes = constants.token_bytes, .interceptors = interceptors };
}

/// The handlers of both services over `App`, and their entries in a route table:
/// `Service(App).routes`. Each handler passes the call to the function of the same name in
/// `repositories.zig` or `issues.zig`, with the service's room.
pub fn Service(comptime App: type) type {
    return struct {
        const Self = @This();
        pub const reads = options_with(&.{ Auth(App, false), RateLimit(App) });
        pub const writes = options_with(&.{ Auth(App, true), RateLimit(App) });

        pub const routes = .{
            rpc.post(App, Repositories.get_repository, Self.get_repository, reads),
            rpc.get(App, Repositories.get_repository, Self.get_repository, reads),
            rpc.post(App, Repositories.list_repositories, Self.list_repositories, reads),
            rpc.get(App, Repositories.list_repositories, Self.list_repositories, reads),
            rpc.post(App, Repositories.create_repository, Self.create_repository, writes),
            rpc.post(App, Issues.create_issue, Self.create_issue, writes),
            rpc.post(App, Issues.get_issue, Self.get_issue, reads),
            rpc.get(App, Issues.get_issue, Self.get_issue, reads),
            rpc.post(App, Issues.list_issues, Self.list_issues, reads),
            rpc.get(App, Issues.list_issues, Self.list_issues, reads),
            rpc.post(App, Issues.update_issue, Self.update_issue, writes),
            rpc.post(App, Issues.import_issues, Self.ImportIssues, writes),
            rpc.post(App, Issues.watch_events, Self.watch_events, reads),
        };

        pub fn get_repository(app: *App, _: *rpc.Context, request: *const rpc.Request(github.GetRepositoryRequest), response: *rpc.Response(github.Repository)) ?connect.RpcError {
            return repositories.get_repository(&app.github, request, response);
        }

        pub fn list_repositories(app: *App, _: *rpc.Context, request: *const rpc.Request(github.ListRepositoriesRequest), response: *rpc.Response(github.ListRepositoriesResponse)) ?connect.RpcError {
            return repositories.list_repositories(&app.github, request, response);
        }

        pub fn create_repository(app: *App, _: *rpc.Context, request: *const rpc.Request(github.CreateRepositoryRequest), response: *rpc.Response(github.Repository)) ?connect.RpcError {
            return repositories.create_repository(&app.github, request, response);
        }

        pub fn create_issue(app: *App, _: *rpc.Context, request: *const rpc.Request(github.CreateIssueRequest), response: *rpc.Response(github.Issue)) ?connect.RpcError {
            return issues.create_issue(&app.github, request, response);
        }

        pub fn get_issue(app: *App, _: *rpc.Context, request: *const rpc.Request(github.GetIssueRequest), response: *rpc.Response(github.Issue)) ?connect.RpcError {
            return issues.get_issue(&app.github, request, response);
        }

        pub fn list_issues(app: *App, _: *rpc.Context, request: *const rpc.Request(github.ListIssuesRequest), response: *rpc.Response(github.ListIssuesResponse)) ?connect.RpcError {
            return issues.list_issues(&app.github, request, response);
        }

        pub fn update_issue(app: *App, _: *rpc.Context, request: *const rpc.Request(github.UpdateIssueRequest), response: *rpc.Response(github.Issue)) ?connect.RpcError {
            return issues.update_issue(&app.github, request, response);
        }

        /// Opens one issue for each message, as it arrives, and answers with their numbers.
        pub const ImportIssues = struct {
            pub const State = issues.ImportState;

            pub fn on_message(app: *App, _: *rpc.Context, state: *State, request: *const rpc.Request(github.CreateIssueRequest)) ?connect.RpcError {
                return issues.import_message(&app.github, state, request);
            }

            pub fn on_end(_: *App, _: *rpc.Context, state: *State, _: *const rpc.AnyRequest, response: *rpc.Response(github.ImportIssuesResponse)) ?connect.RpcError {
                return issues.import_end(state, response);
            }
        };

        pub fn watch_events(app: *App, _: *rpc.Context, request: *const rpc.Request(github.WatchEventsRequest), response: *rpc.ResponseStream(github.Event)) ?connect.RpcError {
            return issues.watch_events(&app.github, request, response);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = store_file;
    _ = repositories;
}
