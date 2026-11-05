//! connect: the Connect, gRPC and gRPC-Web protocols as functions over header values and body
//! octets (design §6). It imports no HTTP library, does no I/O and reads no clock (decisions 2
//! and 3). `connect_colibri` maps it onto colibri.
const std = @import("std");

pub const constants = @import("constants.zig");

const files = struct {
    pub const code = @import("code.zig");
    pub const envelope = @import("envelope.zig");
    pub const protocol = @import("protocol.zig");
    pub const timeout = @import("timeout.zig");
    pub const compression = @import("compression.zig");
    pub const method = @import("method.zig");
    pub const rpc_error = @import("rpc_error.zig");
    pub const json_read = @import("json_read.zig");
    pub const error_json = @import("error_json.zig");
    pub const end_stream = @import("end_stream.zig");
    pub const trailers = @import("trailers.zig");
    pub const get = @import("get.zig");
    pub const message_codec = @import("message_codec.zig");
    pub const server_head = @import("server_head.zig");
    pub const server_request = @import("server_request.zig");
    pub const server_reply = @import("server_reply.zig");
    pub const client_call = @import("client_call.zig");
    pub const client_response = @import("client_response.zig");
};

pub const Code = files.code.Code;
pub const Protocol = files.protocol.Protocol;
pub const Codec = files.protocol.Codec;
pub const Speaks = files.protocol.Speaks;
pub const Method = files.method.Method;
pub const StreamType = files.method.StreamType;
pub const Idempotency = files.method.Idempotency;
pub const Header = files.rpc_error.Header;
pub const Detail = files.rpc_error.Detail;
pub const RpcError = files.rpc_error.RpcError;
/// google.rpc.Status, which gRPC's grpc-status-details-bin carries.
pub const Status = files.rpc_error.Status;
pub const Coding = files.compression.Coding;
pub const Decoders = files.compression.Decoders;
pub const GzipEncoder = files.compression.GzipEncoder;
/// The gzip decoder a caller places for `Decoders.gzip`.
pub const GzipDecoder = files.compression.GzipDecoder;
pub const Envelope = files.envelope.Envelope;
pub const EnvelopeFlags = files.envelope.Flags;
pub const EnvelopeReader = files.envelope.Reader;
pub const EndStream = files.end_stream.EndStream;
/// The storage one message takes while it is encoded or decoded.
pub const Scratch = files.message_codec.Scratch;
/// Finds a header's value by name through the HTTP library's own lookup.
pub const Lookup = files.server_head.Lookup;

/// A server's side of a call: the head, the request's messages, and the reply.
pub const server = struct {
    pub const accept = files.server_head.accept;
    pub const Options = files.server_head.Options;
    pub const Accepted = files.server_head.Accepted;
    pub const Refused = files.server_head.Refused;
    pub const Decision = files.server_head.Decision;
    pub const Messages = files.server_request.Messages;
    pub const ReadError = files.server_request.Error;
    pub const failure_of = files.server_request.failure_of;
    pub const Reply = files.server_reply.Reply;
    pub const ReplyError = files.server_reply.Error;
    pub const Head = files.server_reply.Head;
    pub const Prepared = files.server_reply.Prepared;
    pub const refusal_reply = files.server_reply.refusal_reply;
};

/// A client's side of a call: the request, and the reading of the response.
pub const client = struct {
    pub const request = files.client_call.request;
    pub const Options = files.client_call.Options;
    pub const Buffers = files.client_call.Buffers;
    pub const Request = files.client_call.Request;
    pub const RequestError = files.client_call.Error;
    pub const request_headers_max = files.client_call.request_headers_max;
    pub const read = files.client_response.read;
    pub const Incoming = files.client_response.Incoming;
    pub const Storage = files.client_response.Storage;
    pub const Response = files.client_response.Response;
    pub const ReadError = files.client_response.Error;
    pub const failure_of = files.client_response.failure_of;
};

/// The 5-octet prefix of a streamed message.
pub const envelope = struct {
    pub const write = files.envelope.write;
    pub const write_prefix = files.envelope.write_prefix;
    pub const Error = files.envelope.Error;
};

/// Which protocol a request speaks, and the Content-Type each protocol writes.
pub const protocol = struct {
    pub const of_content_type = files.protocol.of_content_type;
    pub const content_type = files.protocol.content_type;
};

pub const timeout = struct {
    pub const parse_connect = files.timeout.parse_connect;
    pub const format_connect = files.timeout.format_connect;
    pub const parse_grpc = files.timeout.parse_grpc;
    pub const format_grpc = files.timeout.format_grpc;
};

pub const compression = struct {
    pub const decompress = files.compression.decompress;
    pub const compress_gzip = files.compression.compress_gzip;
    pub const choose = files.compression.choose;
    pub const accept_list_len_max = files.compression.accept_list_len_max;
    pub const Error = files.compression.Error;
};

/// The Connect error body.
pub const error_json = struct {
    pub const encode = files.error_json.encode;
    pub const decode = files.error_json.decode;
    pub const Storage = files.error_json.Storage;
};

/// Connect's end-stream message.
pub const end_stream = struct {
    pub const encode = files.end_stream.encode;
    pub const decode = files.end_stream.decode;
    pub const Storage = files.end_stream.Storage;
};

/// gRPC's status trailers and gRPC-Web's trailers frame.
pub const trailers = struct {
    pub const write = files.trailers.write;
    pub const read = files.trailers.read;
    pub const trailers_max = files.trailers.trailers_max;
    pub const Storage = files.trailers.Storage;
    pub const percent_encode = files.trailers.percent_encode;
    pub const percent_decode = files.trailers.percent_decode;
    pub const write_web_frame = files.trailers.write_web_frame;
    pub const read_web_frame = files.trailers.read_web_frame;
};

/// The unary GET of a method with no side effects.
pub const get = struct {
    pub const write_query = files.get.write_query;
    pub const read_query = files.get.read_query;
    pub const message_octets = files.get.message_octets;
    pub const Query = files.get.Query;
};

/// google.rpc.Status in binary.
pub const status = struct {
    pub const encode = files.rpc_error.encode_status;
    pub const decode = files.rpc_error.decode_status;
};

test "the root exports the names a program calls" {
    try @import("public_names").expect(@This(), &.{
        "constants",      "Code",        "Protocol",    "Codec",       "Speaks",   "Method",
        "StreamType",     "Idempotency", "Header",      "Detail",      "RpcError", "Status",
        "Coding",         "Decoders",    "GzipEncoder", "GzipDecoder", "Envelope", "EnvelopeFlags",
        "EnvelopeReader", "EndStream",   "envelope",    "protocol",    "timeout",  "compression",
        "error_json",     "end_stream",  "trailers",    "get",         "status",   "Scratch",
        "Lookup",         "server",      "client",
    });
}

test {
    std.testing.refAllDecls(files);
    _ = @import("exchange_test.zig");
}
