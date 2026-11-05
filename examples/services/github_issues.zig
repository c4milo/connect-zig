//! IssueService of the GitHub-style service: issues and their events, over the store and the
//! helpers of `github.zig`.
//!
//! - UpdateIssue changes only the fields its mask names, as AIP-134 asks, and refuses a path it
//!   does not know.
//! - ImportIssues is a type handler: it opens each issue as its message arrives, and answers with
//!   their numbers once the client ends its stream.
//! - WatchEvents streams a repository's events after a cursor, each with a oneof payload.
const std = @import("std");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const github = @import("github");
const store_file = @import("github_store.zig");
const service = @import("github.zig");
const App = @import("app.zig").App;
const Room = service.Room;
const users = store_file.users;

/// The paths of an update mask, at most: one for each field it may name.
const mask_paths_max = 4;
const Path = enum { title, body, state, labels };

pub fn issue_message(room: *const Room, entry: *const store_file.Issue) github.Issue {
    return .{
        .id = entry.id,
        .repository = room.store.repositories[entry.repository].full_name,
        .number = entry.number,
        .title = entry.title,
        .body = entry.body,
        .state = entry.state,
        .author = users[entry.author],
        .labels = .of(entry.labels[0..entry.labels_len]),
        .created_at = .{ .seconds = entry.created_seconds },
        .closed_at = if (entry.closed_seconds) |seconds| .{ .seconds = seconds } else null,
    };
}

fn event_message(event: *const store_file.Event) github.Event {
    var message: github.Event = .{
        .id = event.id,
        .actor = users[event.actor],
        .created_at = .{ .seconds = event.created_seconds },
        .issue_number = event.issue_number,
    };
    message.payload = switch (event.kind) {
        .opened => |title| .{ .opened = .{ .title = title } },
        .closed => .{ .closed = .{} },
        .labeled => |label| .{ .labeled = .{ .label = label } },
    };
    return message;
}

/// Opens an issue on a repository the caller may see, which the caller's token names the author
/// of. CreateIssue and each message of ImportIssues come here.
fn open(app: *App, call: *const rpc.Call, request: *const github.CreateIssueRequest) union(enum) { issue: *store_file.Issue, failure: connect.RpcError } {
    const room = &app.github;
    const index = switch (service.visible_repository(room, call, request.owner, request.repository)) {
        .index => |index| index,
        .failure => |failure| return .{ .failure = failure },
    };
    if (request.title.len == 0) return .{ .failure = service.bad_field(room, "title", "must not be empty") };
    // `Auth(true)` let the call through, so its token names a user.
    const author = service.caller(call).?;
    const entry = room.store.add_issue(index, author, request) catch |failure| return .{ .failure = service.store_failure(room, failure, "labels") };
    return .{ .issue = entry };
}

pub fn create_issue(app: *App, call: *rpc.Call, request: *const github.CreateIssueRequest, response: *github.Issue) ?connect.RpcError {
    const entry = switch (open(app, call, request)) {
        .issue => |entry| entry,
        .failure => |failure| return failure,
    };
    response.* = issue_message(&app.github, entry);
    return null;
}

const FoundIssue = union(enum) { issue: *store_file.Issue, failure: connect.RpcError };

fn visible_issue(room: *Room, call: *const rpc.Call, owner: []const u8, repository: []const u8, number: i32) FoundIssue {
    const index = switch (service.visible_repository(room, call, owner, repository)) {
        .index => |index| index,
        .failure => |failure| return .{ .failure = failure },
    };
    const entry = room.store.issue(index, number) orelse
        return .{ .failure = service.not_found(room, "Issue", "{s}/{s}#{d}", .{ owner, repository, number }) };
    return .{ .issue = entry };
}

pub fn get_issue(app: *App, call: *rpc.Call, request: *const github.GetIssueRequest, response: *github.Issue) ?connect.RpcError {
    const entry = switch (visible_issue(&app.github, call, request.owner, request.repository, request.number)) {
        .issue => |entry| entry,
        .failure => |failure| return failure,
    };
    response.* = issue_message(&app.github, entry);
    return null;
}

pub fn list_issues(app: *App, call: *rpc.Call, request: *const github.ListIssuesRequest, response: *github.ListIssuesResponse) ?connect.RpcError {
    const room = &app.github;
    const index = switch (service.visible_repository(room, call, request.owner, request.repository)) {
        .index => |index| index,
        .failure => |failure| return failure,
    };
    const page = switch (service.page_of(room, request.page_size, request.page_token)) {
        .page => |page| page,
        .failure => |failure| return failure,
    };
    var total: usize = 0;
    var count: usize = 0;
    for (room.store.issues[0..room.store.issues_len]) |*entry| {
        if (entry.repository != index or !matches(entry, request)) continue;
        if (total >= page.offset and count < page.size) {
            room.issues[count] = issue_message(room, entry);
            count += 1;
        }
        total += 1;
    }
    response.* = .{ .issues = .of(room.issues[0..count]), .next_page_token = page.next_token(room, total), .total_count = @intCast(total) };
    return null;
}

/// Whether an issue passes a list's filter: its state, when set, and its label, when set.
fn matches(entry: *const store_file.Issue, request: *const github.ListIssuesRequest) bool {
    if (request.state != .issue_state_unspecified and entry.state != request.state) return false;
    if (request.label.len == 0) return true;
    for (entry.labels[0..entry.labels_len]) |label| {
        if (std.mem.eql(u8, label, request.label)) return true;
    }
    return false;
}

pub fn update_issue(app: *App, call: *rpc.Call, request: *const github.UpdateIssueRequest, response: *github.Issue) ?connect.RpcError {
    const room = &app.github;
    const entry = switch (visible_issue(room, call, request.owner, request.repository, request.number)) {
        .issue => |entry| entry,
        .failure => |failure| return failure,
    };
    const actor = service.caller(call).?;
    if (actor != entry.author and actor != room.store.repositories[entry.repository].owner) {
        return .{ .code = .permission_denied, .message = "Must be the issue's author or the repository's owner" };
    }
    const paths = switch (paths_of(room, request)) {
        .paths => |paths| paths,
        .failure => |failure| return failure,
    };
    const values = request.issue orelse github.Issue{};
    if (paths.contains(.title) and values.title.len == 0) return service.bad_field(room, "issue.title", "must not be empty");
    if (paths.contains(.state) and values.state != .issue_state_open and values.state != .issue_state_closed) {
        return service.bad_field(room, "issue.state", "must be ISSUE_STATE_OPEN or ISSUE_STATE_CLOSED");
    }
    apply(room, entry, actor, paths, &values) catch |failure| return service.store_failure(room, failure, "issue.labels");
    response.* = issue_message(room, entry);
    return null;
}

const Paths = std.EnumSet(Path);

/// The fields an update's mask names. A mask with no path, or with a path this service does not
/// know, is refused (AIP-134, "Update mask").
fn paths_of(room: *Room, request: *const github.UpdateIssueRequest) union(enum) { paths: Paths, failure: connect.RpcError } {
    const mask = request.update_mask orelse return .{ .failure = service.bad_field(room, "update_mask", "name at least one field") };
    var paths: Paths = .initEmpty();
    var iterator = mask.paths.iterator();
    for (0..mask_paths_max + 1) |_| {
        const path = (iterator.next() catch return .{ .failure = service.internal }) orelse break;
        const known = std.meta.stringToEnum(Path, path) orelse
            return .{ .failure = service.bad_field(room, "update_mask", "paths are title, body, state and labels") };
        paths.insert(known);
    } else return .{ .failure = service.bad_field(room, "update_mask", "too many paths") };
    if (paths.count() == 0) return .{ .failure = service.bad_field(room, "update_mask", "name at least one field") };
    return .{ .paths = paths };
}

/// Writes the fields `paths` names, once every one of them was checked.
fn apply(room: *Room, entry: *store_file.Issue, actor: usize, paths: Paths, values: *const github.Issue) !void {
    if (paths.contains(.title)) entry.title = try room.store.keep(values.title);
    if (paths.contains(.body)) entry.body = try room.store.keep(values.body);
    if (paths.contains(.labels)) entry.labels_len = try room.store.keep_all(values.labels, &entry.labels);
    if (paths.contains(.state)) try room.store.set_state(entry, actor, values.state);
}

/// Opens one issue for each message, as it arrives, and answers with their numbers.
pub const ImportIssues = struct {
    pub const State = struct {
        numbers: [store_file.issues_max]i32 = undefined,
        count: usize = 0,
    };

    pub fn on_message(app: *App, call: *rpc.Call, state: *State, request: *const github.CreateIssueRequest) ?connect.RpcError {
        // An error ends the call: the issues opened before it stay open, as GitHub's own imports
        // leave them.
        const entry = switch (open(app, call, request)) {
            .issue => |entry| entry,
            .failure => |failure| return failure,
        };
        // The store holds `issues_max` issues, so `numbers` has room for each one it opened.
        state.numbers[state.count] = entry.number;
        state.count += 1;
        return null;
    }

    pub fn on_end(_: *App, _: *rpc.Call, state: *State, response: *github.ImportIssuesResponse) ?connect.RpcError {
        response.* = .{ .created = @intCast(state.count), .numbers = .of(state.numbers[0..state.count]) };
        return null;
    }
};

pub fn watch_events(app: *App, call: *rpc.Call, request: *const github.WatchEventsRequest, sender: *rpc.Sender(github.Event)) ?connect.RpcError {
    const room = &app.github;
    const index = switch (service.visible_repository(room, call, request.owner, request.repository)) {
        .index => |index| index,
        .failure => |failure| return failure,
    };
    for (room.store.events[0..room.store.events_len]) |*event| {
        if (event.repository != index or event.id <= request.after_id) continue;
        sender.send(&event_message(event)) catch return .{ .code = .resource_exhausted, .message = "no room to send an event" };
    }
    return null;
}
