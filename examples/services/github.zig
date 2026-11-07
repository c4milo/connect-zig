//! The GitHub-style service of `examples/proto/github/v1/github.proto`: RepositoryService here, and
//! IssueService in `github_issues.zig`, over the store of `github_store.zig`.
//!
//! Every route runs behind two interceptors:
//!
//! - `Auth(required)` reads "authorization: Bearer <token>". A token the store does not know
//!   fails with unauthenticated, on every route. A route that changes data needs a token.
//! - `RateLimit` counts each caller's calls, anonymous callers together. It adds GitHub's
//!   x-ratelimit-limit and x-ratelimit-remaining headers, and fails with resource_exhausted and
//!   a `RateLimited` detail once the caller used its limit.
//!
//! A failure names its cause in a typed detail: `NotFound`, `AlreadyExists` or `BadField`. A
//! private repository reads as not found to anyone but its owner, as GitHub answers 404.
const std = @import("std");
const connect = @import("connect");
const proto = @import("protobuf");
const rpc = @import("connect_colibri");
const github = @import("github");
const store_file = @import("github_store.zig");
const issues = @import("github_issues.zig");
const App = @import("app.zig").App;
const Store = store_file.Store;
const users = store_file.users;
const Repositories = github.RepositoryService;
const Issues = github.IssueService;

/// The calls an anonymous caller makes, and the calls each user makes, before the rate limit.
pub const limit_anonymous = 10;
pub const limit_user = 100;
/// The largest page a list answers, and the page a request with no size gets.
pub const page_size_max = 20;
const page_size_default = 10;
/// The longest repository name (GitHub's own limit).
const name_len_max = 100;
/// Room for a page token, a resource's name in a detail, and an encoded detail.
const token_len = 20;
const resource_name_len = 256;
const detail_len = 512;

/// The decimal text of each count up to `limit_user`. `Call.add_header` keeps the value's slice
/// until the head goes out, so each value lives as long as the program.
const decimals = table: {
    @setEvalBranchQuota(100_000);
    var table: [limit_user + 1][]const u8 = undefined;
    for (&table, 0..) |*text, count| text.* = std.fmt.comptimePrint("{d}", .{count});
    break :table table;
};

/// The service's part of the example server's `App`: its store, and room for each reply. A reply
/// is encoded before its handler's call returns, so one room serves every call.
pub const Room = struct {
    store: Store = .{},
    repositories: [page_size_max]github.Repository = undefined,
    issues: [page_size_max]github.Issue = undefined,
    token: [token_len]u8 = undefined,
    resource_name: [resource_name_len]u8 = undefined,
    detail_bytes: [detail_len]u8 = undefined,
    details: [1]connect.Detail = undefined,
};

/// Refuses a token the store does not know, and a call with no token when `required`.
pub fn Auth(comptime required: bool) type {
    return struct {
        pub fn on_call(_: *App, call: *rpc.Call) ?connect.RpcError {
            const header = call.request_header("authorization") orelse {
                if (required) return .{ .code = .unauthenticated, .message = "Requires authentication" };
                return null;
            };
            _ = store_file.user_of(header) orelse return .{ .code = .unauthenticated, .message = "Bad credentials" };
            return null;
        }
    };
}

/// Counts each caller's calls, and refuses one past its limit.
pub const RateLimit = struct {
    pub fn on_call(app: *App, call: *rpc.Call) ?connect.RpcError {
        const room = &app.github;
        const who: usize = if (caller(call)) |user| user + 1 else store_file.anonymous;
        const limit: u32 = if (who == store_file.anonymous) limit_anonymous else limit_user;
        const used = room.store.calls[who];
        call.add_header("x-ratelimit-limit", decimals[limit]) catch {};
        if (used >= limit) {
            call.add_header("x-ratelimit-remaining", decimals[0]) catch {};
            const detail: github.RateLimited = .{ .limit = @intCast(limit), .used = @intCast(used) };
            return detailed(room, .resource_exhausted, "API rate limit exceeded", github.RateLimited, &detail);
        }
        room.store.calls[who] = used + 1;
        call.add_header("x-ratelimit-remaining", decimals[limit - used - 1]) catch {};
        return null;
    }
};

/// The user the call's token names, or null for an anonymous call.
pub fn caller(call: *const rpc.Call) ?usize {
    return store_file.user_of(call.request_header("authorization"));
}

/// An error with one detail, which the room holds until the reply is encoded.
pub fn detailed(room: *Room, code: connect.Code, message: []const u8, comptime Detail: type, detail: *const Detail) connect.RpcError {
    const bytes = proto.encode(Detail, detail, &room.detail_bytes) catch return internal;
    room.details[0] = .{ .type_name = Detail.protobuf.full_name, .value = bytes };
    return .{ .code = code, .message = message, .details = &room.details };
}

pub const internal: connect.RpcError = .{ .code = .internal, .message = "internal error" };

pub fn not_found(room: *Room, resource_type: []const u8, comptime format: []const u8, args: anytype) connect.RpcError {
    const name = std.fmt.bufPrint(&room.resource_name, format, args) catch return internal;
    return detailed(room, .not_found, "Not Found", github.NotFound, &.{ .resource_type = resource_type, .resource_name = name });
}

pub fn bad_field(room: *Room, field: []const u8, description: []const u8) connect.RpcError {
    return detailed(room, .invalid_argument, "Validation Failed", github.BadField, &.{ .field = field, .description = description });
}

/// The error a store failure answers: a field with too many values, a full store, or a request
/// whose repeated field does not decode.
pub fn store_failure(room: *Room, failure: anyerror, field: []const u8) connect.RpcError {
    return switch (failure) {
        error.TooMany => bad_field(room, field, "too many values"),
        error.StoreFull => .{ .code = .resource_exhausted, .message = "the example's store is full" },
        else => .{ .code = .invalid_argument, .message = "malformed request" },
    };
}

pub const Found = union(enum) { index: usize, failure: connect.RpcError };

/// The repository `owner/name` if the caller may see it. A private repository reads as not found
/// to anyone but its owner, so its name does not leak.
pub fn visible_repository(room: *Room, call: *const rpc.Call, owner: []const u8, name: []const u8) Found {
    const index = room.store.repository(owner, name) orelse return missing_repository(room, owner, name);
    const entry = &room.store.repositories[index];
    if (entry.visibility == .visibility_private and caller(call) != entry.owner) return missing_repository(room, owner, name);
    return .{ .index = index };
}

fn missing_repository(room: *Room, owner: []const u8, name: []const u8) Found {
    return .{ .failure = not_found(room, "Repository", "{s}/{s}", .{ owner, name }) };
}

/// The page a request asks for: the first item, after a token, and how many.
pub const Page = struct {
    offset: usize,
    size: usize,

    /// The token of the page after this one, or empty when `total` items end on this page.
    pub fn next_token(page: Page, room: *Room, total: usize) []const u8 {
        if (page.offset + page.size >= total) return "";
        return std.fmt.bufPrint(&room.token, "{d}", .{page.offset + page.size}) catch "";
    }
};

pub const Paged = union(enum) { page: Page, failure: connect.RpcError };

/// Reads a list request's size and token. A token is the offset of the page's first item, and
/// opaque to clients: they pass back what a page answered.
pub fn page_of(room: *Room, size: i32, token: []const u8) Paged {
    if (size < 0 or size > page_size_max) return .{ .failure = bad_field(room, "page_size", "must be between 0 and 20") };
    const offset = if (token.len == 0) 0 else std.fmt.parseInt(usize, token, 10) catch
        return .{ .failure = bad_field(room, "page_token", "not a token this server wrote") };
    return .{ .page = .{ .offset = offset, .size = if (size == 0) page_size_default else @intCast(size) } };
}

pub fn repository_message(entry: *const store_file.Repository) github.Repository {
    return .{
        .id = entry.id,
        .owner = users[entry.owner],
        .name = entry.name,
        .full_name = entry.full_name,
        .description = entry.description,
        .visibility = entry.visibility,
        .topics = .of(entry.topics[0..entry.topics_len]),
        .open_issues_count = entry.open_issues,
        .created_at = .{ .seconds = entry.created_seconds },
    };
}

fn get_repository(app: *App, call: *rpc.Call, request: *const github.GetRepositoryRequest, response: *github.Repository) ?connect.RpcError {
    const room = &app.github;
    const index = switch (visible_repository(room, call, request.owner, request.name)) {
        .index => |index| index,
        .failure => |failure| return failure,
    };
    response.* = repository_message(&room.store.repositories[index]);
    return null;
}

fn list_repositories(app: *App, call: *rpc.Call, request: *const github.ListRepositoriesRequest, response: *github.ListRepositoriesResponse) ?connect.RpcError {
    const room = &app.github;
    const owner = user_named(request.owner) orelse return not_found(room, "User", "{s}", .{request.owner});
    const page = switch (page_of(room, request.page_size, request.page_token)) {
        .page => |page| page,
        .failure => |failure| return failure,
    };
    const viewer = caller(call);
    var total: usize = 0;
    var count: usize = 0;
    for (room.store.repositories[0..room.store.repositories_len]) |*entry| {
        if (entry.owner != owner) continue;
        if (entry.visibility == .visibility_private and viewer != owner) continue;
        if (total >= page.offset and count < page.size) {
            room.repositories[count] = repository_message(entry);
            count += 1;
        }
        total += 1;
    }
    response.* = .{ .repositories = .of(room.repositories[0..count]), .next_page_token = page.next_token(room, total) };
    return null;
}

fn create_repository(app: *App, call: *rpc.Call, request: *const github.CreateRepositoryRequest, response: *github.Repository) ?connect.RpcError {
    const room = &app.github;
    // `Auth(true)` let the call through, so its token names a user.
    const owner = caller(call).?;
    if (!valid_name(request.name)) return bad_field(room, "name", "use at most 100 letters, digits, '.', '-' and '_'");
    if (room.store.repository(users[owner].login, request.name) != null) {
        const detail: github.AlreadyExists = .{ .resource_type = "Repository", .resource_name = request.name };
        return detailed(room, .already_exists, "name already exists on this account", github.AlreadyExists, &detail);
    }
    const entry = room.store.add_repository(owner, request) catch |failure| return store_failure(room, failure, "topics");
    response.* = repository_message(entry);
    return null;
}

/// A name GitHub would take: letters, digits, '.', '-' and '_', and neither "." nor "..".
fn valid_name(name: []const u8) bool {
    if (name.len == 0 or name.len > name_len_max) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |octet| {
        if (!std.ascii.isAlphanumeric(octet) and octet != '.' and octet != '-' and octet != '_') return false;
    }
    return true;
}

fn user_named(login: []const u8) ?usize {
    for (users, 0..) |user, index| {
        if (std.mem.eql(u8, user.login, login)) return index;
    }
    return null;
}

/// The routes of both services. A read takes a token or none, a change needs one, and every
/// read with no side effects is served as a GET too.
const reads = options_with(&.{ Auth(false), RateLimit });
const writes = options_with(&.{ Auth(true), RateLimit });

fn options_with(comptime interceptors: []const type) rpc.RouteOptions {
    return .{ .message_bytes = message_bytes, .token_bytes = token_bytes, .interceptors = interceptors };
}

/// The longest message a route reads or writes, a page of issues in JSON among them, and the
/// longest JSON token.
const message_bytes = 8192;
const token_bytes = 4096;

pub const routes = .{
    rpc.post(App, Repositories.get_repository, get_repository, reads),
    rpc.get(App, Repositories.get_repository, get_repository, reads),
    rpc.post(App, Repositories.list_repositories, list_repositories, reads),
    rpc.get(App, Repositories.list_repositories, list_repositories, reads),
    rpc.post(App, Repositories.create_repository, create_repository, writes),
    rpc.post(App, Issues.create_issue, issues.create_issue, writes),
    rpc.post(App, Issues.get_issue, issues.get_issue, reads),
    rpc.get(App, Issues.get_issue, issues.get_issue, reads),
    rpc.post(App, Issues.list_issues, issues.list_issues, reads),
    rpc.get(App, Issues.list_issues, issues.list_issues, reads),
    rpc.post(App, Issues.update_issue, issues.update_issue, writes),
    rpc.post(App, Issues.import_issues, issues.ImportIssues, writes),
    rpc.post(App, Issues.watch_events, issues.watch_events, reads),
};

const testing = std.testing;

test "a repository name takes letters, digits, '.', '-' and '_'" {
    try testing.expect(valid_name("hello-world"));
    try testing.expect(valid_name("connect_zig.v2"));
    try testing.expect(!valid_name(""));
    try testing.expect(!valid_name(".."));
    try testing.expect(!valid_name("a/b"));
    try testing.expect(!valid_name("a b"));
}
