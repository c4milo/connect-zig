//! The messages of google/protobuf/descriptor.proto and google/protobuf/compiler/plugin.proto that
//! the plugin reads and writes, written by hand over connect-zig's own runtime (design §8 step 6).
//! Only the fields the generator reads are named; `decode` drops the rest (decision 5). Both files
//! are proto2, so each singular field has explicit presence and is a `?T`.
const proto = @import("protobuf");
const Repeated = proto.Repeated;
const Descriptor = proto.Descriptor;
const Field = proto.Field;

fn field(comptime name: []const u8, comptime number: u32, comptime kind: proto.Kind) Field {
    return .{ .name = name, .number = number, .kind = kind, .json_name = name, .proto_name = name };
}

/// FieldDescriptorProto.Label.
pub const Label = enum(i32) {
    optional = 1,
    required = 2,
    repeated = 3,
    _,
    pub const protobuf: proto.EnumDescriptor = .{ .full_name = "google.protobuf.FieldDescriptorProto.Label", .values = &.{
        .{ .name = "LABEL_OPTIONAL", .number = 1 }, .{ .name = "LABEL_REQUIRED", .number = 2 }, .{ .name = "LABEL_REPEATED", .number = 3 },
    } };
};

/// FieldDescriptorProto.Type, whose numbers are the wire's type names.
pub const Type = enum(i32) {
    double = 1,
    float = 2,
    int64 = 3,
    uint64 = 4,
    int32 = 5,
    fixed64 = 6,
    fixed32 = 7,
    bool = 8,
    string = 9,
    group = 10,
    message = 11,
    bytes = 12,
    uint32 = 13,
    @"enum" = 14,
    sfixed32 = 15,
    sfixed64 = 16,
    sint32 = 17,
    sint64 = 18,
    _,
    pub const protobuf: proto.EnumDescriptor = .{ .full_name = "google.protobuf.FieldDescriptorProto.Type", .values = &.{} };
};

pub const FieldOptions = struct {
    @"packed": ?bool = null,
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.FieldOptions", .fields = &.{field("packed", 2, .bool)} };
};

pub const FieldDescriptorProto = struct {
    name: ?[]const u8 = null,
    number: ?i32 = null,
    label: ?Label = null,
    type: ?Type = null,
    type_name: ?[]const u8 = null,
    options: ?FieldOptions = null,
    oneof_index: ?i32 = null,
    json_name: ?[]const u8 = null,
    proto3_optional: ?bool = null,
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.FieldDescriptorProto", .fields = &.{
        field("name", 1, .string),       field("number", 3, .int32),      field("label", 4, .@"enum"),
        field("type", 5, .@"enum"),      field("type_name", 6, .string),  field("options", 8, .message),
        field("oneof_index", 9, .int32), field("json_name", 10, .string), field("proto3_optional", 17, .bool),
    } };
};

pub const OneofDescriptorProto = struct {
    name: ?[]const u8 = null,
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.OneofDescriptorProto", .fields = &.{field("name", 1, .string)} };
};

pub const MessageOptions = struct {
    map_entry: ?bool = null,
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.MessageOptions", .fields = &.{field("map_entry", 7, .bool)} };
};

pub const EnumValueDescriptorProto = struct {
    name: ?[]const u8 = null,
    number: ?i32 = null,
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.EnumValueDescriptorProto", .fields = &.{
        field("name", 1, .string), field("number", 2, .int32),
    } };
};

pub const EnumDescriptorProto = struct {
    name: ?[]const u8 = null,
    value: Repeated(EnumValueDescriptorProto, .message) = .{},
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.EnumDescriptorProto", .fields = &.{
        field("name", 1, .string), field("value", 2, .message),
    } };
};

pub const DescriptorProto = struct {
    name: ?[]const u8 = null,
    field: Repeated(FieldDescriptorProto, .message) = .{},
    nested_type: Repeated(DescriptorProto, .message) = .{},
    enum_type: Repeated(EnumDescriptorProto, .message) = .{},
    options: ?MessageOptions = null,
    oneof_decl: Repeated(OneofDescriptorProto, .message) = .{},
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.DescriptorProto", .fields = &.{
        field("name", 1, .string),       field("field", 2, .message),   field("nested_type", 3, .message),
        field("enum_type", 4, .message), field("options", 7, .message), field("oneof_decl", 8, .message),
    } };
};

/// MethodOptions.IdempotencyLevel.
pub const IdempotencyLevel = enum(i32) {
    idempotency_unknown = 0,
    no_side_effects = 1,
    idempotent = 2,
    _,
    pub const protobuf: proto.EnumDescriptor = .{ .full_name = "google.protobuf.MethodOptions.IdempotencyLevel", .values = &.{} };
};

pub const MethodOptions = struct {
    idempotency_level: ?IdempotencyLevel = null,
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.MethodOptions", .fields = &.{field("idempotency_level", 34, .@"enum")} };
};

pub const MethodDescriptorProto = struct {
    name: ?[]const u8 = null,
    input_type: ?[]const u8 = null,
    output_type: ?[]const u8 = null,
    options: ?MethodOptions = null,
    client_streaming: ?bool = null,
    server_streaming: ?bool = null,
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.MethodDescriptorProto", .fields = &.{
        field("name", 1, .string),     field("input_type", 2, .string),     field("output_type", 3, .string),
        field("options", 4, .message), field("client_streaming", 5, .bool), field("server_streaming", 6, .bool),
    } };
};

pub const ServiceDescriptorProto = struct {
    name: ?[]const u8 = null,
    method: Repeated(MethodDescriptorProto, .message) = .{},
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.ServiceDescriptorProto", .fields = &.{
        field("name", 1, .string), field("method", 2, .message),
    } };
};

pub const FileDescriptorProto = struct {
    name: ?[]const u8 = null,
    package: ?[]const u8 = null,
    dependency: Repeated([]const u8, .string) = .{},
    message_type: Repeated(DescriptorProto, .message) = .{},
    enum_type: Repeated(EnumDescriptorProto, .message) = .{},
    service: Repeated(ServiceDescriptorProto, .message) = .{},
    syntax: ?[]const u8 = null,
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.FileDescriptorProto", .fields = &.{
        field("name", 1, .string),          field("package", 2, .string),    field("dependency", 3, .string),
        field("message_type", 4, .message), field("enum_type", 5, .message), field("service", 6, .message),
        field("syntax", 12, .string),
    } };
};

pub const CodeGeneratorRequest = struct {
    file_to_generate: Repeated([]const u8, .string) = .{},
    parameter: ?[]const u8 = null,
    proto_file: Repeated(FileDescriptorProto, .message) = .{},
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.compiler.CodeGeneratorRequest", .fields = &.{
        field("file_to_generate", 1, .string), field("parameter", 2, .string), field("proto_file", 15, .message),
    } };
};

pub const GeneratedFile = struct {
    name: ?[]const u8 = null,
    content: ?[]const u8 = null,
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.compiler.CodeGeneratorResponse.File", .fields = &.{
        field("name", 1, .string), field("content", 15, .string),
    } };
};

/// CodeGeneratorResponse.Feature: FEATURE_PROTO3_OPTIONAL is 1.
pub const feature_proto3_optional: u64 = 1;

pub const CodeGeneratorResponse = struct {
    @"error": ?[]const u8 = null,
    supported_features: ?u64 = null,
    file: Repeated(GeneratedFile, .message) = .{},
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.compiler.CodeGeneratorResponse", .fields = &.{
        field("error", 1, .string), field("supported_features", 2, .uint64), field("file", 15, .message),
    } };
};
