//! The data of the GitHub-style service of `github.zig`: users, repositories, issues and events, in
//! fixed tables with no allocator. A request's strings live only as long as its call, so the
//! store copies each one it keeps into `text`.
//!
//! The store keeps its own clock: each change takes the next second after `epoch_seconds`. The
//! examples then check the same timestamps on every run. A real service reads its clock.
const std = @import("std");
const github = @import("github");

/// The most repositories, issues and events the store holds, and the octets of their text.
pub const repositories_max = 16;
pub const issues_max = 64;
pub const events_max = 128;
pub const text_len = 16 * 1024;
/// The most topics of a repository, and labels of an issue.
pub const topics_max = 4;
pub const labels_max = 4;
/// The instant of the store's first change: 2027-01-15T08:00:00Z.
pub const epoch_seconds: i64 = 1_800_000_000;

/// The callers the rate limit counts apart: anyone with no token, then each user.
pub const anonymous = 0;
/// The users, by index. A token names one: "Bearer <token>".
pub const users = [_]github.User{ .{ .login = "octocat", .id = 583231 }, .{ .login = "hubot", .id = 480938 } };
pub const tokens = [_][]const u8{ "ghp_octocat_example", "ghp_hubot_example" };
pub const callers_count = users.len + 1;

pub const Error = error{ StoreFull, TooMany };

pub const Repository = struct {
    id: i64,
    /// An index into `users`.
    owner: usize,
    name: []const u8,
    /// "owner/name", which each of its issues names it by.
    full_name: []const u8,
    description: []const u8,
    visibility: github.Visibility,
    topics: [topics_max][]const u8,
    topics_len: usize,
    created_seconds: i64,
    /// The number the next issue takes, and the issues still open.
    next_issue_number: i32,
    open_issues: i32,
};

pub const Issue = struct {
    id: i64,
    /// An index into `repositories`.
    repository: usize,
    number: i32,
    title: []const u8,
    body: []const u8,
    state: github.IssueState,
    /// An index into `users`.
    author: usize,
    labels: [labels_max][]const u8,
    labels_len: usize,
    created_seconds: i64,
    closed_seconds: ?i64,
};

pub const EventKind = union(enum) { opened: []const u8, closed, labeled: []const u8 };

pub const Event = struct {
    id: i64,
    repository: usize,
    issue_number: i32,
    actor: usize,
    created_seconds: i64,
    kind: EventKind,
};

pub const Store = struct {
    repositories: [repositories_max]Repository = undefined,
    repositories_len: usize = 0,
    issues: [issues_max]Issue = undefined,
    issues_len: usize = 0,
    events: [events_max]Event = undefined,
    events_len: usize = 0,
    text: [text_len]u8 = undefined,
    text_used: usize = 0,
    /// The calls each caller made, which the rate limit reads.
    calls: [callers_count]u32 = @splat(0),
    /// The seconds after `epoch_seconds` of the last change.
    tick: i64 = 0,

    /// Copies `value` into the store's text, so it outlives the request it came in.
    pub fn keep(store: *Store, value: []const u8) Error![]const u8 {
        if (value.len > store.text.len - store.text_used) return error.StoreFull;
        const kept = store.text[store.text_used..][0..value.len];
        @memcpy(kept, value);
        store.text_used += value.len;
        return kept;
    }

    /// The instant of a new change, one second after the one before.
    pub fn now(store: *Store) i64 {
        store.tick += 1;
        return epoch_seconds + store.tick;
    }

    /// The repository `owner/name`, or null.
    pub fn repository(store: *Store, owner: []const u8, name: []const u8) ?usize {
        for (store.repositories[0..store.repositories_len], 0..) |*entry, index| {
            if (std.mem.eql(u8, users[entry.owner].login, owner) and std.mem.eql(u8, entry.name, name)) return index;
        }
        return null;
    }

    /// The issue `number` of a repository, or null.
    pub fn issue(store: *Store, repository_index: usize, number: i32) ?*Issue {
        for (store.issues[0..store.issues_len]) |*entry| {
            if (entry.repository == repository_index and entry.number == number) return entry;
        }
        return null;
    }

    pub fn add_repository(store: *Store, owner: usize, request: *const github.CreateRepositoryRequest) !*Repository {
        if (store.repositories_len == store.repositories.len) return error.StoreFull;
        const entry = &store.repositories[store.repositories_len];
        const login = users[owner].login;
        // The full name, then the name inside it: one copy of the octets serves both.
        const full_name_len = login.len + 1 + request.name.len;
        if (full_name_len > store.text.len - store.text_used) return error.StoreFull;
        const full_name = store.text[store.text_used..][0..full_name_len];
        _ = std.fmt.bufPrint(full_name, "{s}/{s}", .{ login, request.name }) catch unreachable;
        store.text_used += full_name_len;
        entry.* = .{
            .id = @intCast(store.repositories_len + 1),
            .owner = owner,
            .name = full_name[login.len + 1 ..],
            .full_name = full_name,
            .description = try store.keep(request.description),
            .visibility = if (request.visibility == .visibility_private) .visibility_private else .visibility_public,
            .topics = undefined,
            .topics_len = 0,
            .created_seconds = store.now(),
            .next_issue_number = 1,
            .open_issues = 0,
        };
        entry.topics_len = try store.keep_all(request.topics, &entry.topics);
        store.repositories_len += 1;
        return entry;
    }

    /// Opens an issue, and records it opened and each label added.
    pub fn add_issue(store: *Store, repository_index: usize, author: usize, request: *const github.CreateIssueRequest) !*Issue {
        if (store.issues_len == store.issues.len) return error.StoreFull;
        const owner = &store.repositories[repository_index];
        const entry = &store.issues[store.issues_len];
        entry.* = .{
            .id = @intCast(store.issues_len + 1),
            .repository = repository_index,
            .number = owner.next_issue_number,
            .title = try store.keep(request.title),
            .body = try store.keep(request.body),
            .state = .issue_state_open,
            .author = author,
            .labels = undefined,
            .labels_len = 0,
            .created_seconds = store.now(),
            .closed_seconds = null,
        };
        entry.labels_len = try store.keep_all(request.labels, &entry.labels);
        store.issues_len += 1;
        owner.next_issue_number += 1;
        owner.open_issues += 1;
        try store.record(entry, author, .{ .opened = entry.title });
        for (entry.labels[0..entry.labels_len]) |label| try store.record(entry, author, .{ .labeled = label });
        return entry;
    }

    /// Closes an open issue or opens a closed one, and records a close.
    pub fn set_state(store: *Store, entry: *Issue, actor: usize, state: github.IssueState) !void {
        if (state == entry.state) return;
        const owner = &store.repositories[entry.repository];
        entry.state = state;
        if (state == .issue_state_closed) {
            entry.closed_seconds = store.now();
            owner.open_issues -= 1;
            return store.record(entry, actor, .closed);
        }
        entry.closed_seconds = null;
        owner.open_issues += 1;
    }

    /// Copies each string of a repeated field into `into`, and returns how many it copied.
    pub fn keep_all(store: *Store, values: anytype, into: [][]const u8) !usize {
        var count: usize = 0;
        var iterator = values.iterator();
        for (0..into.len + 1) |_| {
            const value = try iterator.next() orelse return count;
            if (count == into.len) return error.TooMany;
            into[count] = try store.keep(value);
            count += 1;
        }
        return error.TooMany;
    }

    fn record(store: *Store, entry: *const Issue, actor: usize, kind: EventKind) !void {
        if (store.events_len == store.events.len) return error.StoreFull;
        store.events[store.events_len] = .{
            .id = @intCast(store.events_len + 1),
            .repository = entry.repository,
            .issue_number = entry.number,
            .actor = actor,
            .created_seconds = epoch_seconds + store.tick,
            .kind = kind,
        };
        store.events_len += 1;
    }
};

/// The user a request's "authorization: Bearer <token>" names, or null for no token or a token
/// the store does not know.
pub fn user_of(authorization: ?[]const u8) ?usize {
    const value = authorization orelse return null;
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    for (tokens, 0..) |token, index| {
        if (std.mem.eql(u8, value[prefix.len..], token)) return index;
    }
    return null;
}

const testing = std.testing;

test "a token names its user, and anything else names none" {
    try testing.expectEqual(@as(?usize, 0), user_of("Bearer ghp_octocat_example"));
    try testing.expectEqual(@as(?usize, 1), user_of("Bearer ghp_hubot_example"));
    try testing.expectEqual(@as(?usize, null), user_of("Bearer ghp_unknown"));
    try testing.expectEqual(@as(?usize, null), user_of("ghp_octocat_example"));
    try testing.expectEqual(@as(?usize, null), user_of(null));
}
