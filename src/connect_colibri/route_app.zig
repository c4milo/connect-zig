//! What a route reads of the program's context, its `App`: the CPU features, the codings, the
//! count of messages past the route's storage, and the receive limit. A field the context
//! lacks takes its default, but `cpu_features`, which every context states.
const std = @import("std");
const connect = @import("connect");
const platform = @import("stdx").platform;

/// The codings a server uses, which the program keeps in a field `codings` of its context. A
/// context with no such field reads and writes uncompressed messages alone.
pub const Codings = struct {
    decoders: connect.Decoders = .{},
    encoders: connect.Encoders = .{},
};

pub fn codings_of(app: anytype) Codings {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "codings")) return app.codings;
    return .{};
}

/// The CPU features a route reads and writes each message with: the context's field
/// `cpu_features`, which the program sets once, as it starts. The module probes no CPU and names
/// none for the program (decision 10 as amended). `protovalidate.Interceptor` reads the same
/// field.
pub fn cpu_features_of(app: anytype) platform.CpuFeatures {
    comptime if (app_error(@TypeOf(app.*))) |problem| @compileError(problem);
    return app.cpu_features;
}

/// What is wrong with the program's context for a route, or null. The message is a compile
/// error of each route.
pub fn app_error(comptime App: type) ?[]const u8 {
    if (@hasField(App, "cpu_features") and @FieldType(App, "cpu_features") == platform.CpuFeatures) return null;
    return "connect_colibri: the routes' context needs a field `cpu_features: platform.CpuFeatures`, stdx's type, which the program sets once as it starts, from `platform.CpuFeatures.detect()`";
}

/// Where the decode counts a binary request message whose repeated fields did not all fit the
/// route's storage: the context's field `messages_past_storage`, when it has one. A count that
/// grows tells the program to raise `storage_bytes`.
pub fn short_count_of(app: anytype) ?*u64 {
    const App = @TypeOf(app.*);
    if (comptime !@hasField(App, "messages_past_storage")) return null;
    comptime if (@FieldType(App, "messages_past_storage") != u64) @compileError("connect_colibri: the context's field `messages_past_storage` is a u64");
    return &app.messages_past_storage;
}

/// The longest request message a route reads: the context's field `message_receive_limit` when
/// it has one and it is not 0, else `message_bytes`. The limit counts a message's octets once
/// decompressed.
pub fn receive_limit_of(app: anytype, comptime message_bytes: usize) usize {
    const App = @TypeOf(app.*);
    if (comptime !@hasField(App, "message_receive_limit")) return message_bytes;
    const limit: usize = app.message_receive_limit;
    if (limit == 0) return message_bytes;
    return @min(limit, message_bytes);
}

const testing = std.testing;
const support = @import("pull_test_support.zig");

test "the receive limit is the context's when it is set and smaller, else message_bytes" {
    const message_bytes = 100;
    const Limited = struct { message_receive_limit: u32 = 0 };
    var limited: Limited = .{ .message_receive_limit = 40 };
    try testing.expectEqual(@as(usize, 40), receive_limit_of(&limited, message_bytes));
    limited.message_receive_limit = 0;
    try testing.expectEqual(@as(usize, message_bytes), receive_limit_of(&limited, message_bytes));
    limited.message_receive_limit = message_bytes + 1;
    try testing.expectEqual(@as(usize, message_bytes), receive_limit_of(&limited, message_bytes));
    const Plain = struct {};
    var plain: Plain = .{};
    try testing.expectEqual(@as(usize, message_bytes), receive_limit_of(&plain, message_bytes));
}

test "a context states its CPU features in a field of stdx's type, and a route reads them" {
    const Stated = struct { cpu_features: platform.CpuFeatures };
    try testing.expectEqual(@as(?[]const u8, null), app_error(Stated));
    try testing.expect(app_error(struct {}) != null);
    // A field of another type is no statement of the CPU's features.
    try testing.expect(app_error(struct { cpu_features: bool }) != null);
    // The route reads the context's own value, which differs here from the tests' and from none.
    var stated: Stated = .{ .cpu_features = .{ .ssse3 = true } };
    try testing.expect(!std.meta.eql(stated.cpu_features, support.cpu_features));
    try testing.expectEqual(stated.cpu_features, cpu_features_of(&stated));
}
