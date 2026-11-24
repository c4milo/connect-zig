//! Example: a GitHub-style API, `proto/github/v1/github.proto`, served by the service of
//! `src/service/` and called the way a real client would use it.
//!
//! Both sides run in one process over the in-memory links of the harness. One session runs over
//! h2, then again over h3, each on a fresh store:
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
//! Anything other than the expected answers exits with an error, which is how `zig build test`
//! knows the example works. Run it with `zig build run`.
const std = @import("std");
const connect = @import("connect_zig").connect;
const proto = @import("connect_zig").protobuf;
const client = @import("connect_zig").client;
const harness = @import("harness");
const github = @import("github");
const service = @import("github_service");
const constants = @import("constants.zig");
const app_file = @import("app.zig");
const App = app_file.App;
const Router = app_file.Router;
const Repositories = github.RepositoryService;
const Issues = github.IssueService;

comptime {
    _ = harness.hooks;
}

pub const Error = error{CallWrong};

comptime {
    // Step 6 sends its calls at once, so the router must answer each of them at once.
    std.debug.assert(constants.burst_len < constants.requests);
}

const CreateRepositoryCall = harness.Call(Repositories.create_repository, .{});
const GetRepositoryCall = harness.Call(Repositories.get_repository, .{});
const ListRepositoriesCall = harness.Call(Repositories.list_repositories, .{});
const CreateIssueCall = harness.Call(Issues.create_issue, .{});
const GetIssueCall = harness.Call(Issues.get_issue, .{});
const ListIssuesCall = harness.Call(Issues.list_issues, .{});
const UpdateIssueCall = harness.Call(Issues.update_issue, .{});
const ImportIssuesCall = harness.Call(Issues.import_issues, .{});
const WatchEventsCall = harness.Call(Issues.watch_events, .{});

/// All the program holds, which `main` allocates once (decision 42). colibri reads and writes
/// each call until its round ends, so the calls live here.
const State = struct {
    app: App,
    /// What the program's calls share: the CPU features it detected (decision 51).
    client: connect.Client,
    /// Decodes the detail of an error, with the CPU features the program detected once.
    protobuf_decoder: proto.Decoder,
    rounds: harness.Rounds(App, Router),
    create_repository: CreateRepositoryCall,
    get_repository: GetRepositoryCall,
    list_repositories: ListRepositoriesCall,
    create_issue: CreateIssueCall,
    get_issue: GetIssueCall,
    list_issues: ListIssuesCall,
    update_issue: UpdateIssueCall,
    import_issues: ImportIssuesCall,
    watch_events: WatchEventsCall,
    burst: [constants.burst_len]GetRepositoryCall,
    /// The token of the next page of a list, which the client sends back.
    page_token: [constants.page_token_len]u8,
    /// The protocols of the session that runs, and the protocol each call's connection speaks.
    protocols: client.Protocols,
    expected: client.Protocol,
};

/// What each caller sends: octocat's token, hubot's, or none.
const octocat = [_]connect.Header{.{ .name = "authorization", .value = "Bearer " ++ service.tokens[0] }};
const hubot = [_]connect.Header{.{ .name = "authorization", .value = "Bearer " ++ service.tokens[1] }};

/// The topics of octocat's first repository.
const topics = [_][]const u8{ "zig", "rpc" };
/// The issues octocat imports, and the one hubot opens.
const imported = [_]github.CreateIssueRequest{
    .{ .owner = "octocat", .repository = "hello-world", .title = "Crash on start", .labels = .of(&.{"bug"}) },
    .{ .owner = "octocat", .repository = "hello-world", .title = "Typo in the README", .labels = .of(&.{"docs"}) },
    .{ .owner = "octocat", .repository = "hello-world", .title = "Slow startup", .labels = .of(&.{ "bug", "performance" }) },
    .{ .owner = "octocat", .repository = "hello-world", .title = "Add a logo" },
};
const readme: github.CreateIssueRequest = .{ .owner = "octocat", .repository = "hello-world", .title = "Add a README", .labels = .of(&.{"docs"}) };
/// The pages the open issues take at `page_size` issues each.
const pages_expected = (imported.len + constants.page_size - 1) / constants.page_size;

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
    try session(state, .{ .h11 = false, .h3 = false }, .h2);
    try session(state, .{ .h11 = false, .h2 = false }, .h3);
    std.debug.print("github: every call answered as expected over h2 and h3\n", .{});
}

fn session(state: *State, protocols: client.Protocols, expected: client.Protocol) !void {
    state.protocols = protocols;
    state.expected = expected;
    state.app.github = .{};
    try create_repositories(state);
    try private_repository(state);
    try open_issues(state);
    try update_issues(state);
    try read_issues(state);
    try read_events(state);
    try rate_limit(state);
    std.debug.print("github: over {s}, the whole session answered as expected\n", .{@tagName(expected)});
}

/// Runs one call alone, so each step sees what the steps before it changed.
fn call(state: *State, client_call: anytype, options: connect.client.Options, messages: MessagesOf(@TypeOf(client_call))) !void {
    try state.rounds.begin(state.protocols);
    try client_call.init(&state.client, {}, &options, messages);
    try state.rounds.request(&client_call.call.request, &client_call.call.response);
    try state.rounds.finish(state.expected);
}

/// The request messages a call's `init` takes, its last parameter, so a call's literals take
/// their type.
fn MessagesOf(comptime Pointer: type) type {
    const Call = @typeInfo(Pointer).pointer.child;
    const parameters = @typeInfo(@TypeOf(Call.init)).@"fn".params;
    return parameters[parameters.len - 1].type.?;
}

/// The one message a call answered. Its strings stay valid until the next `read`.
fn answer(state: *State, comptime T: type, client_call: anytype) !T {
    var response = client_call.call.read(state.rounds.storage());
    const message = try response.next(T) orelse {
        if (response.failure) |failure| std.debug.print("github: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.CallWrong;
    };
    try harness.expect_end(&response, T);
    return message;
}

/// The error a call failed with, which must be `code`.
fn failed_with(state: *State, comptime T: type, client_call: anytype, code: connect.Code) !connect.RpcError {
    var response = client_call.call.read(state.rounds.storage());
    if (try response.next(T) != null) return error.CallWrong;
    const failed = response.failure orelse return error.CallWrong;
    if (failed.code != code) {
        std.debug.print("github: wanted {s}, got {s}: {s}\n", .{ code.name(), failed.code.name(), failed.message });
        return error.CallWrong;
    }
    return failed;
}

/// The one detail of an error, decoded as `Detail`.
fn detail(state: *const State, comptime Detail: type, failed: connect.RpcError) !Detail {
    if (failed.details.len != 1) return error.CallWrong;
    if (!std.mem.eql(u8, failed.details[0].type_name, Detail.protobuf.full_name)) return error.CallWrong;
    return state.protobuf_decoder.decode(Detail, failed.details[0].value);
}

fn expect(condition: bool) !void {
    if (!condition) return error.CallWrong;
}

/// Step 1: octocat creates a repository; a second create of its name, and one with no token, fail.
fn create_repositories(state: *State) !void {
    const hello: github.CreateRepositoryRequest = .{ .name = "hello-world", .description = "My first repository", .topics = .of(&topics) };
    const create = &state.create_repository;
    try call(state, create, .{ .headers = &octocat }, &.{hello});
    const created = try answer(state, github.Repository, create);
    try expect(std.mem.eql(u8, created.full_name, "octocat/hello-world"));
    try expect(try created.topics.count() == topics.len and created.visibility == .visibility_public);
    try expect(created.created_at.?.seconds == service.epoch_seconds + 1);

    try call(state, create, .{ .protocol = .grpc, .headers = &octocat }, &.{hello});
    const exists = try detail(state, github.AlreadyExists, try failed_with(state, github.Repository, create, .already_exists));
    try expect(std.mem.eql(u8, exists.resource_name, "hello-world"));

    try call(state, create, .{ .protocol = .grpc_web }, &.{hello});
    _ = try failed_with(state, github.Repository, create, .unauthenticated);
    std.debug.print("github: created octocat/hello-world; a second create and an anonymous one failed\n", .{});
}

/// Step 2: a private repository reads as not found to anyone but its owner.
fn private_repository(state: *State) !void {
    const secrets: github.CreateRepositoryRequest = .{ .name = "secrets", .visibility = .visibility_private };
    try call(state, &state.create_repository, .{ .codec = .json, .headers = &octocat }, &.{secrets});
    _ = try answer(state, github.Repository, &state.create_repository);

    const get = &state.get_repository;
    const read: github.GetRepositoryRequest = .{ .owner = "octocat", .name = "secrets" };
    try call(state, get, .{ .codec = .json, .use_get = true }, &.{read});
    const missing = try detail(state, github.NotFound, try failed_with(state, github.Repository, get, .not_found));
    try expect(std.mem.eql(u8, missing.resource_name, "octocat/secrets"));

    try call(state, get, .{ .use_get = true, .headers = &octocat }, &.{read});
    try expect((try answer(state, github.Repository, get)).visibility == .visibility_private);

    try call(state, &state.list_repositories, .{ .use_get = true }, &.{.{ .owner = "octocat" }});
    try expect(try (try answer(state, github.ListRepositoriesResponse, &state.list_repositories)).repositories.count() == 1);
    std.debug.print("github: octocat/secrets reads as not found to anyone but octocat\n", .{});
}

/// Step 3: octocat imports four issues in one client stream; hubot opens a fifth.
fn open_issues(state: *State) !void {
    try call(state, &state.import_issues, .{ .protocol = .grpc_web, .headers = &octocat }, &imported);
    const result = try answer(state, github.ImportIssuesResponse, &state.import_issues);
    try expect(result.created == imported.len);
    var numbers = result.numbers.iterator();
    for (1..imported.len + 1) |number| try expect((try numbers.next()).? == number);

    try call(state, &state.create_issue, .{ .codec = .json, .headers = &hubot }, &.{readme});
    const opened = try answer(state, github.Issue, &state.create_issue);
    try expect(opened.number == imported.len + 1 and std.mem.eql(u8, opened.author.?.login, "hubot"));
    std.debug.print("github: octocat imported issues #1 to #4 in one stream, hubot opened #5\n", .{});
}

/// Step 4: hubot may not close octocat's issue; octocat closes it, and a mask must name known fields.
fn update_issues(state: *State) !void {
    const close: github.UpdateIssueRequest = .{
        .owner = "octocat",
        .repository = "hello-world",
        .number = 1,
        .issue = .{ .state = .issue_state_closed, .title = "ignored: the mask does not name it" },
        .update_mask = .{ .paths = .of(&.{"state"}) },
    };
    const update = &state.update_issue;
    try call(state, update, .{ .protocol = .grpc, .headers = &hubot }, &.{close});
    _ = try failed_with(state, github.Issue, update, .permission_denied);

    try call(state, update, .{ .headers = &octocat }, &.{close});
    const closed = try answer(state, github.Issue, update);
    try expect(closed.state == .issue_state_closed and closed.closed_at != null);
    try expect(std.mem.eql(u8, closed.title, "Crash on start"));

    var color = close;
    // A known path beside an unknown one: the server refuses the whole update, not just the part
    // it does not know.
    color.update_mask = .{ .paths = .of(&.{ "title", "color" }) };
    try call(state, update, .{ .codec = .json, .headers = &octocat }, &.{color});
    const bad = try detail(state, github.BadField, try failed_with(state, github.Issue, update, .invalid_argument));
    try expect(std.mem.eql(u8, bad.field, "update_mask"));
    std.debug.print("github: octocat closed #1 through a field mask; hubot could not\n", .{});
}

/// Step 5: page through the open issues `page_size` at a time, then filter by label, and miss one.
fn read_issues(state: *State) !void {
    var request: github.ListIssuesRequest = .{ .owner = "octocat", .repository = "hello-world", .state = .issue_state_open, .page_size = constants.page_size };
    const list = &state.list_issues;
    var seen: usize = 0;
    var pages: usize = 0;
    // Each page names the next one's token, until the last page names none.
    for (0..imported.len) |_| {
        try call(state, list, .{ .use_get = true, .codec = .json }, &.{request});
        const page = try answer(state, github.ListIssuesResponse, list);
        try expect(page.total_count == imported.len);
        seen += try page.issues.count();
        pages += 1;
        if (page.next_page_token.len == 0) break;
        // The token lives in the response's storage, which the next read reuses: keep a copy.
        if (page.next_page_token.len > state.page_token.len) return error.CallWrong;
        @memcpy(state.page_token[0..page.next_page_token.len], page.next_page_token);
        request.page_token = state.page_token[0..page.next_page_token.len];
    }
    try expect(seen == imported.len and pages == pages_expected);

    try call(state, list, .{}, &.{.{ .owner = "octocat", .repository = "hello-world", .label = "bug" }});
    const bugs = try answer(state, github.ListIssuesResponse, list);
    var labeled = bugs.issues.iterator();
    for (constants.bug_numbers) |number| try expect((try labeled.next()).?.number == number);
    try expect(try labeled.next() == null);

    try call(state, &state.get_issue, .{ .protocol = .grpc }, &.{.{ .owner = "octocat", .repository = "hello-world", .number = constants.missing_issue_number }});
    const missing = try detail(state, github.NotFound, try failed_with(state, github.Issue, &state.get_issue, .not_found));
    try expect(std.mem.eql(u8, missing.resource_name, std.fmt.comptimePrint("octocat/hello-world#{d}", .{constants.missing_issue_number})));
    std.debug.print("github: read {d} open issues in {d} pages, and the bugs #1 and #3\n", .{ seen, pages });
}

/// Step 5, continued: every event in a server stream, then only those after a cursor.
fn read_events(state: *State) !void {
    const watch = &state.watch_events;
    try call(state, watch, .{}, &.{.{ .owner = "octocat", .repository = "hello-world" }});
    var response = watch.call.read(state.rounds.storage());
    var count: usize = 0;
    var last: github.Event = .{};
    for (0..constants.events_count + 1) |_| {
        last = try response.next(github.Event) orelse break;
        count += 1;
    }
    try harness.expect_end(&response, github.Event);
    try expect(count == constants.events_count and last.payload.? == .closed and last.issue_number == 1);

    try call(state, watch, .{ .protocol = .grpc }, &.{.{ .owner = "octocat", .repository = "hello-world", .after_id = constants.events_count - 1 }});
    try expect((try answer(state, github.Event, watch)).id == constants.events_count);
    std.debug.print("github: streamed {d} events, then the one after the cursor\n", .{count});
}

/// Step 6: `burst_len` anonymous calls at once; the limit lets through what is left of it.
fn rate_limit(state: *State) !void {
    // The server's count of anonymous calls, which a client learns from x-ratelimit-remaining.
    const left = service.limit_anonymous - state.app.github.store.calls[service.anonymous];
    try expect(left < constants.burst_len);
    try state.rounds.begin(state.protocols);
    for (&state.burst) |*client_call| {
        try client_call.init(&state.client, {}, &.{}, &.{.{ .owner = "octocat", .name = "hello-world" }});
        try state.rounds.request(&client_call.call.request, &client_call.call.response);
    }
    try state.rounds.finish(state.expected);
    var answered: usize = 0;
    var limited: usize = 0;
    for (&state.burst) |*client_call| {
        var response = client_call.call.read(state.rounds.storage());
        if (try response.next(github.Repository) != null) {
            answered += 1;
            continue;
        }
        const limit = try detail(state, github.RateLimited, response.failure orelse return error.CallWrong);
        try expect(response.failure.?.code == .resource_exhausted and limit.limit == service.limit_anonymous);
        limited += 1;
    }
    try expect(answered == left and limited == constants.burst_len - left);
    std.debug.print("github: of {d} anonymous calls at once, {d} answered and {d} hit the rate limit\n", .{ state.burst.len, answered, limited });
}
