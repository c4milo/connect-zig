//! The messages of google/protobuf/descriptor.proto and google/protobuf/compiler/plugin.proto that
//! the plugin reads and writes, written by hand over connect-zig's own runtime (design §8 step 6).
//! Only the fields the generator reads are named; `decode` drops the rest (decision 5). Both files
//! are proto2, so each singular field has explicit presence and is a `?T`.
const proto = @import("protobuf");
const Repeated = proto.Repeated;
const Descriptor = proto.Descriptor;
const field_of = proto.field_of;

/// FieldDescriptorProto.Label.
pub const Label = enum(i32) {
    optional = 1,
    required = 2,
    repeated = 3,
    _,
    pub const protobuf: proto.EnumDescriptor = .{ .full_name = "google.protobuf.FieldDescriptorProto.Label", .values = &.{
        .{ .name = "LABEL_OPTIONAL", .number = @intFromEnum(@This().optional) },
        .{ .name = "LABEL_REQUIRED", .number = @intFromEnum(@This().required) },
        .{ .name = "LABEL_REPEATED", .number = @intFromEnum(@This().repeated) },
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
    pub const FieldNumber = enum(u29) { @"packed" = 2 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.FieldOptions", .fields = &.{field_of(FieldNumber.@"packed", .bool, .{})} };
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
    pub const FieldNumber = enum(u29) { name = 1, number = 3, label = 4, type = 5, type_name = 6, options = 8, oneof_index = 9, json_name = 10, proto3_optional = 17 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.FieldDescriptorProto", .fields = &.{
        field_of(FieldNumber.name, .string, .{}),       field_of(FieldNumber.number, .int32, .{}),     field_of(FieldNumber.label, .@"enum", .{}),
        field_of(FieldNumber.type, .@"enum", .{}),      field_of(FieldNumber.type_name, .string, .{}), field_of(FieldNumber.options, .message, .{}),
        field_of(FieldNumber.oneof_index, .int32, .{}), field_of(FieldNumber.json_name, .string, .{}), field_of(FieldNumber.proto3_optional, .bool, .{}),
    } };
};

pub const OneofDescriptorProto = struct {
    name: ?[]const u8 = null,
    pub const FieldNumber = enum(u29) { name = 1 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.OneofDescriptorProto", .fields = &.{field_of(FieldNumber.name, .string, .{})} };
};

pub const MessageOptions = struct {
    map_entry: ?bool = null,
    pub const FieldNumber = enum(u29) { map_entry = 7 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.MessageOptions", .fields = &.{field_of(FieldNumber.map_entry, .bool, .{})} };
};

pub const EnumValueDescriptorProto = struct {
    name: ?[]const u8 = null,
    number: ?i32 = null,
    pub const FieldNumber = enum(u29) { name = 1, number = 2 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.EnumValueDescriptorProto", .fields = &.{
        field_of(FieldNumber.name, .string, .{}), field_of(FieldNumber.number, .int32, .{}),
    } };
};

pub const EnumDescriptorProto = struct {
    name: ?[]const u8 = null,
    value: Repeated(EnumValueDescriptorProto, .message) = .{},
    pub const FieldNumber = enum(u29) { name = 1, value = 2 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.EnumDescriptorProto", .fields = &.{
        field_of(FieldNumber.name, .string, .{}), field_of(FieldNumber.value, .message, .{}),
    } };
};

pub const DescriptorProto = struct {
    name: ?[]const u8 = null,
    field: Repeated(FieldDescriptorProto, .message) = .{},
    nested_type: Repeated(DescriptorProto, .message) = .{},
    enum_type: Repeated(EnumDescriptorProto, .message) = .{},
    options: ?MessageOptions = null,
    oneof_decl: Repeated(OneofDescriptorProto, .message) = .{},
    pub const FieldNumber = enum(u29) { name = 1, field = 2, nested_type = 3, enum_type = 4, options = 7, oneof_decl = 8 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.DescriptorProto", .fields = &.{
        field_of(FieldNumber.name, .string, .{}),       field_of(FieldNumber.field, .message, .{}),   field_of(FieldNumber.nested_type, .message, .{}),
        field_of(FieldNumber.enum_type, .message, .{}), field_of(FieldNumber.options, .message, .{}), field_of(FieldNumber.oneof_decl, .message, .{}),
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
    pub const FieldNumber = enum(u29) { idempotency_level = 34 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.MethodOptions", .fields = &.{field_of(FieldNumber.idempotency_level, .@"enum", .{})} };
};

pub const MethodDescriptorProto = struct {
    name: ?[]const u8 = null,
    input_type: ?[]const u8 = null,
    output_type: ?[]const u8 = null,
    options: ?MethodOptions = null,
    client_streaming: ?bool = null,
    server_streaming: ?bool = null,
    pub const FieldNumber = enum(u29) { name = 1, input_type = 2, output_type = 3, options = 4, client_streaming = 5, server_streaming = 6 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.MethodDescriptorProto", .fields = &.{
        field_of(FieldNumber.name, .string, .{}),     field_of(FieldNumber.input_type, .string, .{}),     field_of(FieldNumber.output_type, .string, .{}),
        field_of(FieldNumber.options, .message, .{}), field_of(FieldNumber.client_streaming, .bool, .{}), field_of(FieldNumber.server_streaming, .bool, .{}),
    } };
};

pub const ServiceDescriptorProto = struct {
    name: ?[]const u8 = null,
    method: Repeated(MethodDescriptorProto, .message) = .{},
    pub const FieldNumber = enum(u29) { name = 1, method = 2 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.ServiceDescriptorProto", .fields = &.{
        field_of(FieldNumber.name, .string, .{}), field_of(FieldNumber.method, .message, .{}),
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
    pub const FieldNumber = enum(u29) { name = 1, package = 2, dependency = 3, message_type = 4, enum_type = 5, service = 6, syntax = 12 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.FileDescriptorProto", .fields = &.{
        field_of(FieldNumber.name, .string, .{}),          field_of(FieldNumber.package, .string, .{}),    field_of(FieldNumber.dependency, .string, .{}),
        field_of(FieldNumber.message_type, .message, .{}), field_of(FieldNumber.enum_type, .message, .{}), field_of(FieldNumber.service, .message, .{}),
        field_of(FieldNumber.syntax, .string, .{}),
    } };
};

pub const CodeGeneratorRequest = struct {
    file_to_generate: Repeated([]const u8, .string) = .{},
    parameter: ?[]const u8 = null,
    proto_file: Repeated(FileDescriptorProto, .message) = .{},
    pub const FieldNumber = enum(u29) { file_to_generate = 1, parameter = 2, proto_file = 15 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.compiler.CodeGeneratorRequest", .fields = &.{
        field_of(FieldNumber.file_to_generate, .string, .{}), field_of(FieldNumber.parameter, .string, .{}), field_of(FieldNumber.proto_file, .message, .{}),
    } };
};

pub const GeneratedFile = struct {
    name: ?[]const u8 = null,
    content: ?[]const u8 = null,
    pub const FieldNumber = enum(u29) { name = 1, content = 15 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.compiler.CodeGeneratorResponse.File", .fields = &.{
        field_of(FieldNumber.name, .string, .{}), field_of(FieldNumber.content, .string, .{}),
    } };
};

/// CodeGeneratorResponse.Feature: FEATURE_PROTO3_OPTIONAL is 1.
pub const feature_proto3_optional: u64 = 1;

pub const CodeGeneratorResponse = struct {
    @"error": ?[]const u8 = null,
    supported_features: ?u64 = null,
    file: Repeated(GeneratedFile, .message) = .{},
    pub const FieldNumber = enum(u29) { @"error" = 1, supported_features = 2, file = 15 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.compiler.CodeGeneratorResponse", .fields = &.{
        field_of(FieldNumber.@"error", .string, .{}), field_of(FieldNumber.supported_features, .uint64, .{}), field_of(FieldNumber.file, .message, .{}),
    } };
};
