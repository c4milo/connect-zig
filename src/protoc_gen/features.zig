//! The edition features that change the code the generator writes, resolved for one field from
//! its file down through each enclosing message (protobuf editions, "Feature Resolution"). A
//! proto2 or proto3 file has no features of its own; its syntax sets the same three choices.
const std = @import("std");
const pb = @import("descriptor_pb.zig");

pub const Features = struct {
    /// Whether a singular scalar outside a oneof has presence, and so is a `?T`.
    explicit_presence: bool,
    /// Whether a repeated scalar is packed.
    @"packed": bool,
    /// Whether a message field is written between group tags rather than after its length.
    delimited: bool,

    /// The features a file's syntax or edition starts from. Editions 2023 and 2024 default to
    /// explicit presence, packed repeated scalars and length-prefixed messages.
    pub fn of_file(file: pb.FileDescriptorProto) Features {
        const syntax = file.syntax orelse "proto2";
        if (std.mem.eql(u8, syntax, "proto3")) return .{ .explicit_presence = false, .@"packed" = true, .delimited = false };
        if (std.mem.eql(u8, syntax, "editions")) {
            const defaults: Features = .{ .explicit_presence = true, .@"packed" = true, .delimited = false };
            const options = file.options orelse return defaults;
            return defaults.merge(options.features);
        }
        return .{ .explicit_presence = true, .@"packed" = false, .delimited = false };
    }

    /// These features, with each one `set` names in its place.
    pub fn merge(features: Features, set: ?pb.FeatureSet) Features {
        const named = set orelse return features;
        var result = features;
        if (named.field_presence) |presence| {
            // LEGACY_REQUIRED is a field with presence that must be set; the runtime does not
            // check required fields, so it reads as explicit (decision 23).
            if (presence != 0) result.explicit_presence = presence != pb.presence_implicit;
        }
        if (named.repeated_field_encoding) |encoding| {
            if (encoding != 0) result.@"packed" = encoding == pb.encoding_packed;
        }
        if (named.message_encoding) |encoding| {
            if (encoding != 0) result.delimited = encoding == pb.message_delimited;
        }
        return result;
    }

    /// The features of a message's fields: these, with the message's own on top. A map entry's
    /// key and value never have presence, and its value is always written with a length,
    /// whatever the syntax or edition ("Maps"; editions, "message_encoding").
    pub fn of_message(features: Features, message: pb.DescriptorProto) Features {
        const options = message.options orelse return features;
        var result = features.merge(options.features);
        if (options.map_entry orelse false) {
            result.explicit_presence = false;
            result.delimited = false;
        }
        return result;
    }

    /// The features of one field.
    pub fn of_field(features: Features, field: pb.FieldDescriptorProto) Features {
        const options = field.options orelse return features;
        return features.merge(options.features);
    }
};

const testing = std.testing;

test "each syntax starts from its own choices, and an edition from its defaults" {
    const proto3 = Features.of_file(.{ .syntax = "proto3" });
    try testing.expect(!proto3.explicit_presence and proto3.@"packed");
    const proto2 = Features.of_file(.{});
    try testing.expect(proto2.explicit_presence and !proto2.@"packed");
    const edition = Features.of_file(.{ .syntax = "editions", .edition = 1000 });
    try testing.expect(edition.explicit_presence and edition.@"packed" and !edition.delimited);
}

test "a field's features override its message's, which override its file's" {
    const file = Features.of_file(.{ .syntax = "editions", .options = .{ .features = .{ .field_presence = pb.presence_implicit } } });
    try testing.expect(!file.explicit_presence);
    const message = file.of_message(.{ .options = .{ .features = .{ .message_encoding = pb.message_delimited } } });
    try testing.expect(message.delimited and !message.explicit_presence);
    const field = message.of_field(.{ .options = .{ .features = .{ .field_presence = pb.presence_legacy_required, .repeated_field_encoding = pb.encoding_expanded } } });
    try testing.expect(field.explicit_presence and !field.@"packed" and field.delimited);
    // A map entry's fields have no presence, even in an edition that gives fields presence.
    try testing.expect(!file.merge(.{ .field_presence = pb.presence_explicit }).of_message(.{ .options = .{ .map_entry = true } }).explicit_presence);
    // An unknown value, 0, leaves the parent's choice.
    try testing.expect(!message.of_field(.{ .options = .{ .features = .{ .field_presence = 0 } } }).explicit_presence);
}
