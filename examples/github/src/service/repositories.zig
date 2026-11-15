//! RepositoryService of the GitHub-style service: repositories, over the store of `store.zig` and
//! the replies of `room.zig`. Each handler takes the service's room, which `Service(App)` passes.
const std = @import("std");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const github = @import("github");
const store_file = @import("store.zig");
const room_file = @import("room.zig");
const constants = @import("constants.zig");
const Room = room_file.Room;
const users = store_file.users;

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

pub fn get_repository(room: *Room, request: *const rpc.Request(github.GetRepositoryRequest), response: *rpc.Response(github.Repository)) ?connect.RpcError {
    const index = switch (room_file.visible_repository(room, &request.any, request.message.owner, request.message.name)) {
        .index => |index| index,
        .failure => |failure| return failure,
    };
    response.message = repository_message(&room.store.repositories[index]);
    return null;
}

pub fn list_repositories(room: *Room, request: *const rpc.Request(github.ListRepositoriesRequest), response: *rpc.Response(github.ListRepositoriesResponse)) ?connect.RpcError {
    const asked = &request.message;
    const owner = user_named(asked.owner) orelse return room_file.not_found(room, "User", "{s}", .{asked.owner});
    const page = switch (room_file.page_of(room, asked.page_size, asked.page_token)) {
        .page => |page| page,
        .failure => |failure| return failure,
    };
    const viewer = room_file.caller(&request.any);
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
    response.message = .{ .repositories = .of(room.repositories[0..count]), .next_page_token = page.next_token(room, total) };
    return null;
}

pub fn create_repository(room: *Room, request: *const rpc.Request(github.CreateRepositoryRequest), response: *rpc.Response(github.Repository)) ?connect.RpcError {
    const asked = &request.message;
    // `Auth(App, true)` let the call through, so its token names a user.
    const owner = room_file.caller(&request.any).?;
    if (!valid_name(asked.name)) return room_file.bad_field(room, "name", name_rule);
    if (room.store.repository(users[owner].login, asked.name) != null) {
        const detail: github.AlreadyExists = .{ .resource_type = "Repository", .resource_name = asked.name };
        return room_file.detailed(room, .already_exists, "name already exists on this account", github.AlreadyExists, &detail);
    }
    const entry = room.store.add_repository(owner, asked) catch |failure| return room_file.store_failure(room, failure, "topics");
    response.message = repository_message(entry);
    return null;
}

const name_rule = std.fmt.comptimePrint("use at most {d} letters, digits, '.', '-' and '_'", .{constants.name_len_max});

/// A name GitHub would take: letters, digits, '.', '-' and '_', and neither "." nor "..".
fn valid_name(name: []const u8) bool {
    if (name.len == 0 or name.len > constants.name_len_max) return false;
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

const testing = std.testing;

test "a repository name takes letters, digits, '.', '-' and '_'" {
    try testing.expect(valid_name("hello-world"));
    try testing.expect(valid_name("connect_zig.v2"));
    try testing.expect(!valid_name(""));
    try testing.expect(!valid_name(".."));
    try testing.expect(!valid_name("a/b"));
    try testing.expect(!valid_name("a b"));
}
