//! The types an Any in a conformance message may name, which the server and the client each
//! declare as their root's `protobuf_any_types` (decision 21).
const service = @import("connectrpc_conformance_v1_service");

/// The types an Any in a JSON message may name (decision 21): every message the service reads
/// and writes, since a request echoes in a response's `requests`, and an error's details.
pub const types: []const type = &.{
    service.UnaryRequest,                      service.UnaryResponse,
    service.IdempotentUnaryRequest,            service.IdempotentUnaryResponse,
    service.ServerStreamRequest,               service.ServerStreamResponse,
    service.ClientStreamRequest,               service.ClientStreamResponse,
    service.BidiStreamRequest,                 service.BidiStreamResponse,
    service.UnimplementedRequest,              service.UnimplementedResponse,
    service.ConformancePayload,                service.ConformancePayload.RequestInfo,
    service.ConformancePayload.ConnectGetInfo, service.Error,
    service.Header,
};
