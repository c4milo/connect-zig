//! Tests of each type's rules through `validate`: a value at each side of what a rule states,
//! and the id of the rule it breaks.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const support = @import("rule_test_support.zig");
const expect = support.expect;
const expect_message = support.expect_message;

const Text = []const u8;

fn string(comptime rules: pb.StringRules) pb.FieldRules {
    return .{ .type = .{ .string = rules } };
}

fn octets(comptime rules: pb.BytesRules) pb.FieldRules {
    return .{ .type = .{ .bytes = rules } };
}

test "a number's const, lists and finite are each a rule of their own" {
    const rules: pb.FieldRules = comptime .{ .type = .{ .int32 = .{ .@"const" = 5, .in = .of(&.{ 5, 6 }), .not_in = .of(&.{7}) } } };
    try expect(i32, .int32, rules, 5, "");
    try expect(i32, .int32, rules, 6, "int32.const");
    try expect(i32, .int32, rules, 7, "int32.const int32.in int32.not_in");
    try expect_message(i32, .int32, comptime .{ .type = .{ .int32 = .{ .@"const" = 5 } } }, 4, "must equal 5");
    try expect_message(i32, .int32, comptime .{ .type = .{ .int32 = .{ .in = .of(&.{ 5, 6 }) } } }, 4, "must be in list [5, 6]");
    try expect_message(i32, .int32, comptime .{ .type = .{ .int32 = .{ .not_in = .of(&.{ 5, 6 }) } } }, 6, "must not be in list [5, 6]");
    const finite: pb.FieldRules = comptime .{ .type = .{ .double = .{ .finite = true } } };
    try expect(f64, .double, finite, 1.5, "");
    try expect(f64, .double, finite, std.math.inf(f64), "double.finite");
    try expect(f64, .double, finite, -std.math.inf(f64), "double.finite");
    try expect(f64, .double, finite, std.math.nan(f64), "double.finite");
    try expect(f64, .double, comptime .{ .type = .{ .double = .{ .finite = false } } }, std.math.nan(f64), "");
    // NaN equals no number, itself included.
    try expect(f32, .float, comptime .{ .type = .{ .float = .{ .@"const" = std.math.nan(f32) } } }, std.math.nan(f32), "float.const");
    try expect(f32, .float, comptime .{ .type = .{ .float = .{ .greater_than = .{ .gt = 0 } } } }, std.math.nan(f32), "float.gt");
    // A wrapper's rules read the number it holds.
    try expect(?proto.wkt.Int32Value, .message, rules, .{ .value = 6 }, "int32.const");
    try expect(?proto.wkt.Int32Value, .message, rules, null, "");
}

test "each unsigned and each wide number takes its own type's rules" {
    try expect(u64, .uint64, comptime .{ .type = .{ .uint64 = .{ .greater_than = .{ .gte = std.math.maxInt(u64) } } } }, std.math.maxInt(u64) - 1, "uint64.gte");
    try expect(u64, .uint64, comptime .{ .type = .{ .uint64 = .{ .greater_than = .{ .gte = std.math.maxInt(u64) } } } }, std.math.maxInt(u64), "");
    try expect(i64, .sfixed64, comptime .{ .type = .{ .sfixed64 = .{ .less_than = .{ .lte = std.math.minInt(i64) } } } }, std.math.minInt(i64) + 1, "sfixed64.lte");
    try expect(u32, .fixed32, comptime .{ .type = .{ .fixed32 = .{ .less_than = .{ .lt = 1 } } } }, 1, "fixed32.lt");
    try expect(u32, .fixed32, comptime .{ .type = .{ .fixed32 = .{ .less_than = .{ .lt = 1 } } } }, 0, "");
}

test "a bool's const and an enum's rules read the value's number" {
    try expect(bool, .bool, comptime .{ .type = .{ .bool = .{ .@"const" = true } } }, true, "");
    try expect(bool, .bool, comptime .{ .type = .{ .bool = .{ .@"const" = true } } }, false, "bool.const");
    try expect(bool, .bool, comptime .{ .type = .{ .bool = .{ .@"const" = false } } }, true, "bool.const");
    try expect_message(bool, .bool, comptime .{ .type = .{ .bool = .{ .@"const" = false } } }, true, "must equal false");
    const Color = enum(i32) {
        unspecified = 0,
        red = 1,
        blue = 2,
        _,
        pub const protobuf: proto.EnumDescriptor = .{ .full_name = "t.Color", .values = &.{ .{ .name = "UNSPECIFIED", .number = 0 }, .{ .name = "RED", .number = 1 }, .{ .name = "BLUE", .number = 2 } } };
    };
    const rules: pb.FieldRules = comptime .{ .type = .{ .@"enum" = .{ .@"const" = 1, .defined_only = true, .in = .of(&.{ 1, 2 }), .not_in = .of(&.{2}) } } };
    try expect(Color, .@"enum", rules, .red, "");
    try expect(Color, .@"enum", rules, .blue, "enum.const enum.not_in");
    try expect(Color, .@"enum", rules, .unspecified, "enum.const enum.in");
    try expect(Color, .@"enum", rules, @enumFromInt(7), "enum.const enum.defined_only enum.in");
    try expect(Color, .@"enum", comptime .{ .type = .{ .@"enum" = .{ .defined_only = false } } }, @enumFromInt(7), "");
    try expect_message(Color, .@"enum", comptime .{ .type = .{ .@"enum" = .{ .defined_only = true } } }, @enumFromInt(7), "value must be one of the defined enum values");
}

test "a string's const, lists and affixes compare octets" {
    try expect(Text, .string, comptime string(.{ .@"const" = "abc" }), "abc", "");
    try expect(Text, .string, comptime string(.{ .@"const" = "abc" }), "abd", "string.const");
    try expect(Text, .string, comptime string(.{ .@"const" = "abc" }), "ab", "string.const");
    try expect_message(Text, .string, comptime string(.{ .@"const" = "abc" }), "", "must equal `abc`");
    const lists = comptime string(.{ .in = .of(&.{ "a", "b" }), .not_in = .of(&.{"b"}) });
    try expect(Text, .string, lists, "a", "");
    try expect(Text, .string, lists, "b", "string.not_in");
    try expect(Text, .string, lists, "c", "string.in");
    try expect_message(Text, .string, comptime string(.{ .in = .of(&.{ "a", "b" }) }), "c", "must be in list [a, b]");
    const parts = comptime string(.{ .prefix = "ab", .suffix = "yz", .contains = "mn", .not_contains = "q" });
    try expect(Text, .string, parts, "abmnyz", "");
    try expect(Text, .string, parts, "bamnyz", "string.prefix");
    try expect(Text, .string, parts, "abmnzy", "string.suffix");
    try expect(Text, .string, parts, "abnmyz", "string.contains");
    try expect(Text, .string, parts, "abmnqyz", "string.not_contains");
    try expect(Text, .string, parts, "", "string.prefix string.suffix string.contains");
    try expect_message(Text, .string, comptime string(.{ .not_contains = "q" }), "q", "contains substring `q`");
}

test "a string's length counts characters, and its byte length octets" {
    const characters = comptime string(.{ .len = 2 });
    try expect(Text, .string, characters, "你好", "");
    try expect(Text, .string, characters, "你", "string.len");
    try expect(Text, .string, characters, "你好吗", "string.len");
    try expect_message(Text, .string, characters, "a", "must be 2 characters");
    const range = comptime string(.{ .min_len = 2, .max_len = 3 });
    try expect(Text, .string, range, "é", "string.min_len");
    try expect(Text, .string, range, "éé", "");
    try expect(Text, .string, range, "ééé", "");
    try expect(Text, .string, range, "éééé", "string.max_len");
    const bytes = comptime string(.{ .len_bytes = 4 });
    try expect(Text, .string, bytes, "éé", "");
    try expect(Text, .string, bytes, "ééa", "string.len_bytes");
    try expect(Text, .string, bytes, "abc", "string.len_bytes");
    const byte_range = comptime string(.{ .min_bytes = 2, .max_bytes = 3 });
    try expect(Text, .string, byte_range, "a", "string.min_bytes");
    try expect(Text, .string, byte_range, "é", "");
    try expect(Text, .string, byte_range, "abc", "");
    try expect(Text, .string, byte_range, "éé", "string.max_bytes");
    // A StringValue's rules read the string it holds.
    try expect(?proto.wkt.StringValue, .message, range, .{ .value = "a" }, "string.min_len");
}

test "a well-known form refuses the empty string under its own id, then a value of another form" {
    try expect(Text, .string, comptime string(.{ .well_known = .{ .email = true } }), "a@b", "");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .email = true } }), "", "string.email_empty");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .email = true } }), "a", "string.email");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .email = false } }), "a", "");
    try expect_message(Text, .string, comptime string(.{ .well_known = .{ .email = true } }), "", "value is empty, which is not a valid email address");
    try expect_message(Text, .string, comptime string(.{ .well_known = .{ .email = true } }), "a", "must be a valid email address");
    // The empty string is a URI reference, and an HTTP header's value.
    try expect(Text, .string, comptime string(.{ .well_known = .{ .uri_ref = true } }), "", "");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .uri_ref = true } }), ":", "string.uri_ref");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .well_known_regex = .known_regex_http_header_value } }), "", "");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .well_known_regex = .known_regex_http_header_value } }), "a\n", "string.well_known_regex.header_value");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .well_known_regex = .known_regex_http_header_name } }), "", "string.well_known_regex.header_name_empty");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .well_known_regex = .known_regex_http_header_name } }), "a b", "string.well_known_regex.header_name");
    // `strict = false` takes the loose pattern.
    try expect(Text, .string, comptime string(.{ .well_known = .{ .well_known_regex = .known_regex_http_header_name }, .strict = false }), "a b", "");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .well_known_regex = .known_regex_http_header_value }, .strict = false }), "a\x08", "");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .well_known_regex = .known_regex_http_header_value }, .strict = true }), "a\x08", "string.well_known_regex.header_value");
    try expect(Text, .string, comptime string(.{ .well_known = .{ .well_known_regex = .known_regex_unspecified } }), "", "");
}

test "each well-known form asks for its own form, version and strictness" {
    const cases = .{
        .{ pb.StringRules{ .well_known = .{ .hostname = true } }, "example.com", "1.2.3.4", "string.hostname" },
        .{ pb.StringRules{ .well_known = .{ .ip = true } }, "::1", "example.com", "string.ip" },
        .{ pb.StringRules{ .well_known = .{ .ip = true } }, "1.2.3.4", "1.2.3", "string.ip" },
        .{ pb.StringRules{ .well_known = .{ .ipv4 = true } }, "1.2.3.4", "::1", "string.ipv4" },
        .{ pb.StringRules{ .well_known = .{ .ipv6 = true } }, "::1", "1.2.3.4", "string.ipv6" },
        .{ pb.StringRules{ .well_known = .{ .uri = true } }, "a:b", "./b", "string.uri" },
        .{ pb.StringRules{ .well_known = .{ .address = true } }, "example.com", "a..b", "string.address" },
        .{ pb.StringRules{ .well_known = .{ .address = true } }, "::1", "::g", "string.address" },
        .{ pb.StringRules{ .well_known = .{ .uuid = true } }, "8b72987b-024a-43b3-b4cf-647a1f925c5d", "8b72987b024a43b3b4cf647a1f925c5d", "string.uuid" },
        .{ pb.StringRules{ .well_known = .{ .tuuid = true } }, "8b72987b024a43b3b4cf647a1f925c5d", "8b72987b-024a-43b3-b4cf-647a1f925c5d", "string.tuuid" },
        .{ pb.StringRules{ .well_known = .{ .ip_with_prefixlen = true } }, "1.2.3.4/8", "1.2.3.4", "string.ip_with_prefixlen" },
        .{ pb.StringRules{ .well_known = .{ .ip_with_prefixlen = true } }, "::1/8", "::1/129", "string.ip_with_prefixlen" },
        .{ pb.StringRules{ .well_known = .{ .ipv4_with_prefixlen = true } }, "1.2.3.4/8", "::1/8", "string.ipv4_with_prefixlen" },
        .{ pb.StringRules{ .well_known = .{ .ipv6_with_prefixlen = true } }, "::1/8", "1.2.3.4/8", "string.ipv6_with_prefixlen" },
        .{ pb.StringRules{ .well_known = .{ .ip_prefix = true } }, "1.0.0.0/8", "1.2.3.4/8", "string.ip_prefix" },
        .{ pb.StringRules{ .well_known = .{ .ip_prefix = true } }, "1::/16", "1::1/16", "string.ip_prefix" },
        .{ pb.StringRules{ .well_known = .{ .ipv4_prefix = true } }, "1.0.0.0/8", "1::/16", "string.ipv4_prefix" },
        .{ pb.StringRules{ .well_known = .{ .ipv4_prefix = true } }, "1.0.0.0/8", "1.2.3.4/8", "string.ipv4_prefix" },
        .{ pb.StringRules{ .well_known = .{ .ipv6_prefix = true } }, "1::/16", "1.0.0.0/8", "string.ipv6_prefix" },
        .{ pb.StringRules{ .well_known = .{ .ipv6_prefix = true } }, "1::/16", "1::1/16", "string.ipv6_prefix" },
        .{ pb.StringRules{ .well_known = .{ .host_and_port = true } }, "example.com:80", "example.com", "string.host_and_port" },
        .{ pb.StringRules{ .well_known = .{ .ulid = true } }, "01ARZ3NDEKTSV4RRFFQ69G5FAV", "01ARZ3NDEKTSV4RRFFQ69G5FAU", "string.ulid" },
        .{ pb.StringRules{ .well_known = .{ .protobuf_fqn = true } }, "a.b", ".a.b", "string.protobuf_fqn" },
        .{ pb.StringRules{ .well_known = .{ .protobuf_dot_fqn = true } }, ".a.b", "a.b", "string.protobuf_dot_fqn" },
    };
    inline for (cases) |case| {
        const rules = comptime string(case[0]);
        try expect(Text, .string, rules, case[1], "");
        try expect(Text, .string, rules, case[2], case[3]);
        try expect(Text, .string, rules, "", case[3] ++ "_empty");
    }
}

test "a bytes field's const, length, parts and lists compare octets" {
    try expect(Text, .bytes, comptime octets(.{ .@"const" = "\x00\x01" }), "\x00\x01", "");
    try expect(Text, .bytes, comptime octets(.{ .@"const" = "\x00\x01" }), "\x00\x02", "bytes.const");
    try expect_message(Text, .bytes, comptime octets(.{ .@"const" = "\x00\x01" }), "", "must be 0001");
    try expect(Text, .bytes, comptime octets(.{ .len = 2 }), "ab", "");
    try expect(Text, .bytes, comptime octets(.{ .len = 2 }), "a", "bytes.len");
    try expect(Text, .bytes, comptime octets(.{ .len = 2 }), "abc", "bytes.len");
    const range = comptime octets(.{ .min_len = 2, .max_len = 3 });
    try expect(Text, .bytes, range, "a", "bytes.min_len");
    try expect(Text, .bytes, range, "ab", "");
    try expect(Text, .bytes, range, "abc", "");
    try expect(Text, .bytes, range, "abcd", "bytes.max_len");
    try expect_message(Text, .bytes, range, "a", "must be at least 2 bytes");
    const parts = comptime octets(.{ .prefix = "ab", .suffix = "yz", .contains = "mn" });
    try expect(Text, .bytes, parts, "abmnyz", "");
    try expect(Text, .bytes, parts, "bamnyz", "bytes.prefix");
    try expect(Text, .bytes, parts, "abmnzy", "bytes.suffix");
    try expect(Text, .bytes, parts, "abnmyz", "bytes.contains");
    try expect_message(Text, .bytes, comptime octets(.{ .prefix = "ab" }), "", "does not have prefix 6162");
    const lists = comptime octets(.{ .in = .of(&.{ "a", "b" }), .not_in = .of(&.{"b"}) });
    try expect(Text, .bytes, lists, "a", "");
    try expect(Text, .bytes, lists, "b", "bytes.not_in");
    try expect(Text, .bytes, lists, "c", "bytes.in");
    try expect_message(Text, .bytes, comptime octets(.{ .in = .of(&.{ "a", "b" }) }), "c", "must be in list [61, 62]");
    try expect(?proto.wkt.BytesValue, .message, range, .{ .value = "a" }, "bytes.min_len");
}

test "a bytes field's well-known forms are lengths: 4 or 16 octets, and never none" {
    const cases = .{
        .{ pb.BytesRules{ .well_known = .{ .ip = true } }, "bytes.ip", .{ 4, 16 }, .{ 1, 5, 15, 17 } },
        .{ pb.BytesRules{ .well_known = .{ .ipv4 = true } }, "bytes.ipv4", .{4}, .{ 3, 5, 16 } },
        .{ pb.BytesRules{ .well_known = .{ .ipv6 = true } }, "bytes.ipv6", .{16}, .{ 4, 15, 17 } },
        .{ pb.BytesRules{ .well_known = .{ .uuid = true } }, "bytes.uuid", .{16}, .{ 4, 15, 17 } },
    };
    const zeros = "\x00" ** 17;
    inline for (cases) |case| {
        const rules = comptime octets(case[0]);
        inline for (case[2]) |len| try expect(Text, .bytes, rules, zeros[0..len], "");
        inline for (case[3]) |len| try expect(Text, .bytes, rules, zeros[0..len], case[1]);
        try expect(Text, .bytes, rules, "", case[1] ++ "_empty");
    }
    try expect(Text, .bytes, comptime octets(.{ .well_known = .{ .ip = false } }), "a", "");
    try expect_message(Text, .bytes, comptime octets(.{ .well_known = .{ .uuid = true } }), "a", "must be a valid UUID");
    try expect_message(Text, .bytes, comptime octets(.{ .well_known = .{ .ipv4 = true } }), "", "value is empty, which is not a valid IPv4 address");
}
