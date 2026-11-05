//! Example: a GitHub-style API, `examples/proto/github/v1/github.proto`, served by
//! `services/github.zig` and called the way a real client would use it.
//!
//! One session runs over h2, then again over h3, each on a fresh store. Step 6 runs over h2 alone
//! until colibri's h3 client reads a 429:
//!
//! 1. octocat creates a public and a private repository. A second create of the same name fails
//!    with already_exists, and a create with no token with unauthenticated.
//! 2. Anyone reads the public repository, but the private one reads as not found to anyone but
//!    its owner, with a `NotFound` detail.
//! 3. octocat imports four issues in one client stream, and hubot opens a fifth.
//! 4. hubot may not close octocat's issue. octocat closes it through an update mask, and a mask
//!    with a path the server does not know fails with a `BadField` detail.
//! 5. A client pages through the open issues two at a time, filters by label, and reads every
//!    event in a server stream, then only the events after a cursor.
//! 6. Anonymous calls run out of their rate limit: six at once, of which the limit lets through
//!    what the session's earlier anonymous reads left of it. The rest fail with a `RateLimited`
//!    detail.
//!
//! The calls mix Connect in binary and JSON, Connect GET, gRPC-Web and gRPC. `RateLimit` sets
//! headers on every call, so a gRPC error comes in trailers after them, never Trailers-Only, and
//! the client reads it there as it reads a success's status (decision 11).
//!
//! Run it with `zig build example-github`.
const std = @import("std");
const connect = @import("connect");
const proto = @import("protobuf");
const client = @import("client");
const rpc = @import("connect_colibri");
const github = @import("github");
const harness = @import("services/link_client.zig");
const store_file = @import("services/github_store.zig");
const service = @import("services/github.zig");
const Repositories = github.RepositoryService;
const Issues = github.IssueService;

pub const Error = error{CallWrong};

/// What each caller sends: octocat's token, hubot's, or none.
const octocat = [_]connect.Header{.{ .name = "authorization", .value = "Bearer " ++ store_file.tokens[0] }};
const hubot = [_]connect.Header{.{ .name = "authorization", .value = "Bearer " ++ store_file.tokens[1] }};
const anonymous = [_]connect.Header{};

/// The issues octocat imports, and the one hubot opens.
const imported = [_]github.CreateIssueRequest{
    .{ .owner = "octocat", .repository = "hello-world", .title = "Crash on start", .labels = .of(&.{"bug"}) },
    .{ .owner = "octocat", .repository = "hello-world", .title = "Typo in the README", .labels = .of(&.{"docs"}) },
    .{ .owner = "octocat", .repository = "hello-world", .title = "Slow startup", .labels = .of(&.{ "bug", "performance" }) },
    .{ .owner = "octocat", .repository = "hello-world", .title = "Add a logo" },
};
const readme: github.CreateIssueRequest = .{ .owner = "octocat", .repository = "hello-world", .title = "Add a README", .labels = .of(&.{"docs"}) };
/// The events those issues record: five opened, five labels added, and issue #1 closed.
const events_count = 11;
/// The anonymous calls step 6 sends at once: fewer than the server answers at once, which is the
/// router pool's 8 requests.
const burst_len = 6;

var create_repository: rpc.ClientCall(Repositories.create_repository) align(@alignOf(rpc.ClientCall(Repositories.create_repository))) = undefined;
var get_repository: rpc.ClientCall(Repositories.get_repository) align(@alignOf(rpc.ClientCall(Repositories.get_repository))) = undefined;
var list_repositories: rpc.ClientCall(Repositories.list_repositories) align(@alignOf(rpc.ClientCall(Repositories.list_repositories))) = undefined;
var create_issue: rpc.ClientCall(Issues.create_issue) align(@alignOf(rpc.ClientCall(Issues.create_issue))) = undefined;
var get_issue: rpc.ClientCall(Issues.get_issue) align(@alignOf(rpc.ClientCall(Issues.get_issue))) = undefined;
var list_issues: rpc.ClientCall(Issues.list_issues) align(@alignOf(rpc.ClientCall(Issues.list_issues))) = undefined;
var update_issue: rpc.ClientCall(Issues.update_issue) align(@alignOf(rpc.ClientCall(Issues.update_issue))) = undefined;
var import_issues: rpc.ClientCall(Issues.import_issues) align(@alignOf(rpc.ClientCall(Issues.import_issues))) = undefined;
var watch_events: rpc.ClientCall(Issues.watch_events) align(@alignOf(rpc.ClientCall(Issues.watch_events))) = undefined;
var burst: [burst_len]rpc.ClientCall(Repositories.get_repository) align(@alignOf(rpc.ClientCall(Repositories.get_repository))) = undefined;
var buffers: [burst_len]harness.CallBuffers align(@alignOf(harness.CallBuffers)) = undefined;

/// The token of the next page of a list, which the client sends back.
var page_token: [page_token_len]u8 = undefined;
const page_token_len = 32;

/// The protocols of the round that runs, which each call's connection speaks.
var protocols: client.Protocols align(@alignOf(client.Protocols)) = undefined;
var expected: client.Protocol align(@alignOf(client.Protocol)) = undefined;

pub fn main() !void {
    try harness.init();
    defer harness.deinit();
    try session(.{ .h11 = false, .h3 = false }, .h2);
    try session(.{ .h11 = false, .h2 = false }, .h3);
    std.debug.print("github: every call answered as expected over h2 and h3\n", .{});
}

fn session(round_protocols: client.Protocols, round_protocol: client.Protocol) !void {
    protocols = round_protocols;
    expected = round_protocol;
    harness.app.github = .{};
    try repositories();
    try private_repository();
    try open_issues();
    try update_issues();
    try read_issues();
    try read_events();
    // colibri's h3 client panics on a status its enum lacks, and Connect answers
    // resource_exhausted with 429 (RFC 6585 §4). colibri fixes it; until then step 6 runs over
    // TCP alone.
    if (expected != .h3) try rate_limit();
    std.debug.print("github: over {s}, the whole session answered as expected\n", .{@tagName(expected)});
}

/// Runs one call alone, so each step sees what the steps before it changed.
fn call(client_call: anytype, options: connect.client.Options, messages: MessagesOf(@TypeOf(client_call))) !void {
    try harness.begin(protocols);
    try client_call.init(options, messages, harness.buffers(&buffers[0]));
    try harness.request(&client_call.request, &client_call.response);
    try harness.finish(expected);
}

/// The request messages a client call's `init` takes, so a call's literals take their type.
fn MessagesOf(comptime Pointer: type) type {
    const ClientCall = @typeInfo(Pointer).pointer.child;
    return @typeInfo(@TypeOf(ClientCall.init)).@"fn".params[2].type.?;
}

/// The one message a call answered. Its strings stay valid until the next `read`.
fn answer(comptime T: type, client_call: anytype) !T {
    var response = client_call.read(harness.storage());
    const message = try response.next(T) orelse {
        if (response.failure) |failure| std.debug.print("github: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.CallWrong;
    };
    try harness.expect_end(&response, T);
    return message;
}

/// The error a call failed with, which must be `code`.
fn failed_with(comptime T: type, client_call: anytype, code: connect.Code) !connect.RpcError {
    var response = client_call.read(harness.storage());
    if (try response.next(T) != null) return error.CallWrong;
    const failed = response.failure orelse return error.CallWrong;
    if (failed.code != code) {
        std.debug.print("github: wanted {s}, got {s}: {s}\n", .{ code.name(), failed.code.name(), failed.message });
        return error.CallWrong;
    }
    return failed;
}

/// The one detail of an error, decoded as `Detail`.
fn detail(comptime Detail: type, failed: connect.RpcError) !Detail {
    if (failed.details.len != 1) return error.CallWrong;
    if (!std.mem.eql(u8, failed.details[0].type_name, Detail.protobuf.full_name)) return error.CallWrong;
    return proto.decode(Detail, failed.details[0].value);
}

fn expect(condition: bool) !void {
    if (!condition) return error.CallWrong;
}

/// Step 1: octocat creates a repository; a second create of its name, and one with no token, fail.
fn repositories() !void {
    const hello: github.CreateRepositoryRequest = .{ .name = "hello-world", .description = "My first repository", .topics = .of(&.{ "zig", "rpc" }) };
    try call(&create_repository, .{ .headers = &octocat }, &.{hello});
    const created = try answer(github.Repository, &create_repository);
    try expect(std.mem.eql(u8, created.full_name, "octocat/hello-world"));
    try expect(try created.topics.count() == 2 and created.visibility == .visibility_public);
    try expect(created.created_at.?.seconds == store_file.epoch_seconds + 1);

    try call(&create_repository, .{ .protocol = .grpc, .headers = &octocat }, &.{hello});
    const exists = try detail(github.AlreadyExists, try failed_with(github.Repository, &create_repository, .already_exists));
    try expect(std.mem.eql(u8, exists.resource_name, "hello-world"));

    try call(&create_repository, .{ .protocol = .grpc_web }, &.{hello});
    _ = try failed_with(github.Repository, &create_repository, .unauthenticated);
    std.debug.print("github: created octocat/hello-world; a second create and an anonymous one failed\n", .{});
}

/// Step 2: a private repository reads as not found to anyone but its owner.
fn private_repository() !void {
    const secrets: github.CreateRepositoryRequest = .{ .name = "secrets", .visibility = .visibility_private };
    try call(&create_repository, .{ .codec = .json, .headers = &octocat }, &.{secrets});
    _ = try answer(github.Repository, &create_repository);

    const read: github.GetRepositoryRequest = .{ .owner = "octocat", .name = "secrets" };
    try call(&get_repository, .{ .codec = .json, .use_get = true }, &.{read});
    const missing = try detail(github.NotFound, try failed_with(github.Repository, &get_repository, .not_found));
    try expect(std.mem.eql(u8, missing.resource_name, "octocat/secrets"));

    try call(&get_repository, .{ .use_get = true, .headers = &octocat }, &.{read});
    try expect((try answer(github.Repository, &get_repository)).visibility == .visibility_private);

    try call(&list_repositories, .{ .use_get = true }, &.{.{ .owner = "octocat" }});
    try expect(try (try answer(github.ListRepositoriesResponse, &list_repositories)).repositories.count() == 1);
    std.debug.print("github: octocat/secrets reads as not found to anyone but octocat\n", .{});
}

/// Step 3: octocat imports four issues in one client stream; hubot opens a fifth.
fn open_issues() !void {
    try call(&import_issues, .{ .protocol = .grpc_web, .headers = &octocat }, &imported);
    const result = try answer(github.ImportIssuesResponse, &import_issues);
    try expect(result.created == imported.len);
    var numbers = result.numbers.iterator();
    for (1..imported.len + 1) |number| try expect((try numbers.next()).? == number);

    try call(&create_issue, .{ .codec = .json, .headers = &hubot }, &.{readme});
    const opened = try answer(github.Issue, &create_issue);
    try expect(opened.number == imported.len + 1 and std.mem.eql(u8, opened.author.?.login, "hubot"));
    std.debug.print("github: octocat imported issues #1 to #4 in one stream, hubot opened #5\n", .{});
}

/// Step 4: hubot may not close octocat's issue; octocat closes it, and a mask must name known fields.
fn update_issues() !void {
    const close: github.UpdateIssueRequest = .{
        .owner = "octocat",
        .repository = "hello-world",
        .number = 1,
        .issue = .{ .state = .issue_state_closed, .title = "ignored: the mask does not name it" },
        .update_mask = .{ .paths = .of(&.{"state"}) },
    };
    try call(&update_issue, .{ .protocol = .grpc, .headers = &hubot }, &.{close});
    _ = try failed_with(github.Issue, &update_issue, .permission_denied);

    try call(&update_issue, .{ .headers = &octocat }, &.{close});
    const closed = try answer(github.Issue, &update_issue);
    try expect(closed.state == .issue_state_closed and closed.closed_at != null);
    try expect(std.mem.eql(u8, closed.title, "Crash on start"));

    var color = close;
    // A known path beside an unknown one: the server refuses the whole update, not just the part
    // it does not know.
    color.update_mask = .{ .paths = .of(&.{ "title", "color" }) };
    try call(&update_issue, .{ .codec = .json, .headers = &octocat }, &.{color});
    const bad = try detail(github.BadField, try failed_with(github.Issue, &update_issue, .invalid_argument));
    try expect(std.mem.eql(u8, bad.field, "update_mask"));
    std.debug.print("github: octocat closed #1 through a field mask; hubot could not\n", .{});
}

/// Step 5: page through the open issues two at a time, then filter by label, and miss one.
fn read_issues() !void {
    var request: github.ListIssuesRequest = .{ .owner = "octocat", .repository = "hello-world", .state = .issue_state_open, .page_size = 2 };
    var seen: usize = 0;
    var pages: usize = 0;
    // Each page names the next one's token, until the last page names none.
    for (0..imported.len) |_| {
        try call(&list_issues, .{ .use_get = true, .codec = .json }, &.{request});
        const page = try answer(github.ListIssuesResponse, &list_issues);
        try expect(page.total_count == imported.len);
        seen += try page.issues.count();
        pages += 1;
        if (page.next_page_token.len == 0) break;
        // The token lives in the response's storage, which the next read reuses: keep a copy.
        if (page.next_page_token.len > page_token.len) return error.CallWrong;
        @memcpy(page_token[0..page.next_page_token.len], page.next_page_token);
        request.page_token = page_token[0..page.next_page_token.len];
    }
    try expect(seen == imported.len and pages == 2);

    try call(&list_issues, .{}, &.{.{ .owner = "octocat", .repository = "hello-world", .label = "bug" }});
    const bugs = try answer(github.ListIssuesResponse, &list_issues);
    var labeled = bugs.issues.iterator();
    try expect((try labeled.next()).?.number == 1 and (try labeled.next()).?.number == 3 and try labeled.next() == null);

    try call(&get_issue, .{ .protocol = .grpc }, &.{.{ .owner = "octocat", .repository = "hello-world", .number = 42 }});
    const missing = try detail(github.NotFound, try failed_with(github.Issue, &get_issue, .not_found));
    try expect(std.mem.eql(u8, missing.resource_name, "octocat/hello-world#42"));
    std.debug.print("github: read {d} open issues in {d} pages, and the bugs #1 and #3\n", .{ seen, pages });
}

/// Step 5, continued: every event in a server stream, then only those after a cursor.
fn read_events() !void {
    try call(&watch_events, .{}, &.{.{ .owner = "octocat", .repository = "hello-world" }});
    var response = watch_events.read(harness.storage());
    var count: usize = 0;
    var last: github.Event = .{};
    for (0..events_count + 1) |_| {
        last = try response.next(github.Event) orelse break;
        count += 1;
    }
    try harness.expect_end(&response, github.Event);
    try expect(count == events_count and last.payload.? == .closed and last.issue_number == 1);

    try call(&watch_events, .{ .protocol = .grpc }, &.{.{ .owner = "octocat", .repository = "hello-world", .after_id = events_count - 1 }});
    try expect((try answer(github.Event, &watch_events)).id == events_count);
    std.debug.print("github: streamed {d} events, then the one after the cursor\n", .{count});
}

/// Step 6: six anonymous calls at once; the limit lets through what is left of it.
fn rate_limit() !void {
    // The server's count of anonymous calls, which a client learns from x-ratelimit-remaining.
    const left = service.limit_anonymous - harness.app.github.store.calls[store_file.anonymous];
    try expect(left < burst_len);
    try harness.begin(protocols);
    for (&burst, 0..) |*client_call, index| {
        try client_call.init(.{}, &.{.{ .owner = "octocat", .name = "hello-world" }}, harness.buffers(&buffers[index]));
        try harness.request(&client_call.request, &client_call.response);
    }
    try harness.finish(expected);
    var answered: usize = 0;
    var limited: usize = 0;
    for (&burst) |*client_call| {
        var response = client_call.read(harness.storage());
        if (try response.next(github.Repository) != null) {
            answered += 1;
            continue;
        }
        const limit = try detail(github.RateLimited, response.failure orelse return error.CallWrong);
        try expect(response.failure.?.code == .resource_exhausted and limit.limit == service.limit_anonymous);
        limited += 1;
    }
    try expect(answered == left and limited == burst_len - left);
    std.debug.print("github: of {d} anonymous calls at once, {d} answered and {d} hit the rate limit\n", .{ burst.len, answered, limited });
}
