//! A copy of the headers `std.http` parsed. `std.http` reuses the head's octets once a body is
//! read, and connect's server and client look headers up while they read the body.
const std = @import("std");
const connect = @import("connect_zig").connect;
const constants = @import("constants.zig");

pub const Copied = struct {
    octets: [constants.buffer_len]u8,
    entries: [constants.headers_max]connect.Header,
    count: usize,

    /// Copies every header `iterator` gives, or fails when they pass the limits.
    pub fn copy(copied: *Copied, iterator: std.http.HeaderIterator) error{ HeadersTooLarge, TooManyHeaders }!void {
        var headers = iterator;
        var used: usize = 0;
        copied.count = 0;
        for (0..constants.headers_max) |_| {
            const header = headers.next() orelse return;
            const length = header.name.len + header.value.len;
            if (used + length > copied.octets.len) return error.HeadersTooLarge;
            const room = copied.octets[used..][0..length];
            @memcpy(room[0..header.name.len], header.name);
            @memcpy(room[header.name.len..], header.value);
            copied.entries[copied.count] = .{ .name = room[0..header.name.len], .value = room[header.name.len..] };
            copied.count += 1;
            used += length;
        }
        if (headers.next() != null) return error.TooManyHeaders;
    }

    /// What connect looks a header up in, by a name of any case (RFC 9110 §5.1).
    pub fn lookup(copied: *const Copied) connect.Lookup {
        return .{ .context = copied, .find_fn = find };
    }

    fn find(context: *const anyopaque, name: []const u8) ?[]const u8 {
        const copied: *const Copied = @ptrCast(@alignCast(context));
        std.debug.assert(copied.count <= copied.entries.len);
        for (copied.entries[0..copied.count]) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        }
        return null;
    }
};
