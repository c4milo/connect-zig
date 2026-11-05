//! The types an Any's JSON form can name (decision 21). Its JSON names its type in "@type" and
//! spells the message in that type's JSON, so a reader and a writer must know the type. The
//! well-known types are always known. A program adds its own by declaring, in its root file:
//!
//! ```zig
//! pub const protobuf_any_types = .{ my.v1.Order, my.v1.Refund };
//! ```
const std = @import("std");
const root = @import("root");
const wkt = @import("wkt.zig");

pub const well_known = .{
    wkt.Timestamp,  wkt.Duration,    wkt.Empty,       wkt.FieldMask,   wkt.Any,        wkt.Struct,
    wkt.Value,      wkt.ListValue,   wkt.DoubleValue, wkt.FloatValue,  wkt.Int64Value, wkt.UInt64Value,
    wkt.Int32Value, wkt.UInt32Value, wkt.BoolValue,   wkt.StringValue, wkt.BytesValue,
};

const program_types = if (@hasDecl(root, "protobuf_any_types")) root.protobuf_any_types else .{};

/// Every type an Any's JSON can name by default: the well-known types, then the program's.
pub const types = well_known ++ program_types;

/// The well-known types, then `extra`: the registry of `encode_json_with` and `decode_json_with`.
pub fn with(comptime extra: anytype) @TypeOf(well_known ++ extra) {
    return well_known ++ extra;
}

/// The full name an Any's type URL names: what follows its last "/" (any.proto, "type_url").
pub fn full_name_of(url: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return url;
    return url[slash + 1 ..];
}

/// Whether a type's JSON inside an Any sits under "value": every well-known type, since each
/// has a form of its own ("JSON Mapping", Any). Another message's fields sit beside "@type".
pub fn nests_value(comptime T: type) bool {
    return comptime std.mem.startsWith(u8, T.protobuf.full_name, "google.protobuf.");
}

test "a type URL names the full name after its last slash" {
    try std.testing.expectEqualStrings("google.protobuf.Duration", full_name_of("type.googleapis.com/google.protobuf.Duration"));
    try std.testing.expectEqualStrings("a.B", full_name_of("a.B"));
    try std.testing.expect(nests_value(wkt.Empty));
}
