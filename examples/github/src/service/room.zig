//! The service's room, and the replies both services write into it: errors with a typed detail,
//! the repositories a caller may see, and pages.
//!
//! A failure names its cause in a typed detail: `NotFound`, `AlreadyExists` or `BadField`. A
//! private repository reads as not found to anyone but its owner, as GitHub answers 404.
const std = @import("std");
const connect = @import("connect");
const proto = @import("protobuf");
const rpc = @import("connect_colibri");
const github = @import("github");
const store_file = @import("store.zig");
const constants = @import("constants.zig");
const Store = store_file.Store;

/// The service's part of a program's `App`: its store, and room for each reply. A reply is
/// encoded before its handler's call returns, so one room serves every call.
pub const Room = struct {
    store: Store = .{},
    repositories: [constants.page_size_max]github.Repository = undefined,
    issues: [constants.page_size_max]github.Issue = undefined,
    token: [constants.token_len]u8 = undefined,
    resource_name: [constants.resource_name_len]u8 = undefined,
    detail_bytes: [constants.detail_len]u8 = undefined,
    details: [1]connect.Detail = undefined,
};

/// The user the request's token names, or null for an anonymous call.
pub fn caller(request: *const rpc.AnyRequest) ?usize {
    return store_file.user_of(request.header("authorization"));
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
pub fn visible_repository(room: *Room, request: *const rpc.AnyRequest, owner: []const u8, name: []const u8) Found {
    const index = room.store.repository(owner, name) orelse return missing_repository(room, owner, name);
    const entry = &room.store.repositories[index];
    if (entry.visibility == .visibility_private and caller(request) != entry.owner) return missing_repository(room, owner, name);
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

const page_size_rule = std.fmt.comptimePrint("must be between 0 and {d}", .{constants.page_size_max});

/// Reads a list request's size and token. A token is the offset of the page's first item, and
/// opaque to clients: they pass back what a page answered.
pub fn page_of(room: *Room, size: i32, token: []const u8) Paged {
    if (size < 0 or size > constants.page_size_max) return .{ .failure = bad_field(room, "page_size", page_size_rule) };
    const offset = if (token.len == 0) 0 else std.fmt.parseInt(usize, token, constants.page_token_base) catch
        return .{ .failure = bad_field(room, "page_token", "not a token this server wrote") };
    return .{ .page = .{ .offset = offset, .size = if (size == 0) constants.page_size_default else @intCast(size) } };
}
