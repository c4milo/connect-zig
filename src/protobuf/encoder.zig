//! `Encoder`: what writes a message as proto3 JSON, with the program's CPU features. A program
//! makes one as it starts, with the features it detected once, and encodes with it from then on.
//! The binary encoding uses no CPU feature, so `protobuf.encode` needs no encoder.
const std = @import("std");
const json = @import("json");
const platform = @import("platform");
const json_encode = @import("json_encode.zig");
const json_scalar = @import("json_scalar.zig");
const any = @import("any.zig");

pub const Encoder = struct {
    /// The CPU features the JSON writer runs with: the program's, which it detects once with
    /// stdx's `platform.CpuFeatures.detect`.
    cpu_features: platform.CpuFeatures,

    pub fn init(cpu_features: platform.CpuFeatures) Encoder {
        return .{ .cpu_features = cpu_features };
    }

    /// Writes `message` as one proto3 JSON text into `buffer`, and returns the text. An Any names
    /// its type from the well-known types and the root file's `protobuf_any_types` (decision 21).
    pub fn encode_json(encoder: *const Encoder, comptime T: type, message: *const T, buffer: []u8) json_scalar.EncodeError![]const u8 {
        return encode_json_registry(T, message, buffer, encoder.cpu_features, any.types);
    }

    /// `encode_json`, with an Any naming its type from the well-known types and `any_types`.
    pub fn encode_json_with(encoder: *const Encoder, comptime T: type, message: *const T, buffer: []u8, comptime any_types: []const type) json_scalar.EncodeError![]const u8 {
        return encode_json_registry(T, message, buffer, encoder.cpu_features, any.with(any_types));
    }
};

fn encode_json_registry(comptime T: type, message: *const T, buffer: []u8, cpu_features: platform.CpuFeatures, comptime registry: []const type) json_scalar.EncodeError![]const u8 {
    var text = json.TextWriter.init(buffer, .text, cpu_features);
    try json_encode.write_message(T, message, &text, registry);
    return text.written();
}
