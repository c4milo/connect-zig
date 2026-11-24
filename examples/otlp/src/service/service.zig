//! OpenTelemetry's OTLP trace receiver (decision 40): `TraceService/Export` of opentelemetry-proto,
//! which OpenTelemetry's SDKs and its Collector call, and `SpanStore/Received`, which answers with
//! what `Export` kept. A program's `App` holds the receiver's `Room` in its field `otlp`, so one
//! route table may serve it beside other services (decision 41).
//!
//! `Export` keeps the binary encoding of each request after the one before it. Two encodings of
//! one message, one after the other, decode as one message whose repeated fields hold the
//! elements of both (protobuf encoding guide, "Last One Wins"), so `Received` decodes all it kept
//! as one request.
const std = @import("std");
const connect = @import("connect");
const proto = @import("protobuf");
const rpc = @import("connect_colibri");
const otlp = @import("otlp");
const otlpstore = @import("otlpstore");
const constants = @import("constants.zig");

/// The receiver's part of a program's `App`.
pub const Room = struct {
    kept: [constants.kept_len_max]u8 = undefined,
    kept_len: usize = 0,
    /// The spans of the requests `Export` kept, and of those it refused.
    taken: u64 = 0,
    rejected: u64 = 0,
};

pub const Error = error{ ResourcesTooMany, ScopesTooMany };

/// The longest request a route reads, and the longest answer: the kept requests.
pub const route_options: rpc.RouteOptions = .{ .message_bytes = constants.kept_len_max };

/// The receiver's handlers over `App`, and their entries in a route table: `Service(App).routes`.
/// Each handler passes the call to the function below of the same name, with the room.
pub fn Service(comptime App: type) type {
    return struct {
        pub const routes = otlp.TraceService.Routes(rpc, App, @This(), route_options).routes ++
            otlpstore.SpanStore.Routes(rpc, App, @This(), route_options).routes;

        pub fn @"export"(app: *App, _: *rpc.Context, request: *const rpc.Request(otlp.ExportTraceServiceRequest), response: *rpc.Response(otlp.ExportTraceServiceResponse)) ?connect.RpcError {
            return export_in(&app.otlp, request, response);
        }

        pub fn received(app: *App, _: *rpc.Context, _: *const rpc.Request(otlpstore.ReceivedRequest), response: *rpc.Response(otlp.ExportTraceServiceRequest)) ?connect.RpcError {
            // The program's CPU features, which it set once, as it started.
            const decoder: proto.Decoder = .init(app.cpu_features);
            return received_in(&app.otlp, &decoder, response);
        }
    };
}

/// Keeps the request, or refuses all its spans when the room is full. OTLP's answer names the
/// spans a server refused, and a client does not send them again (OTLP specification, "Partial
/// Success").
fn export_in(room: *Room, request: *const rpc.Request(otlp.ExportTraceServiceRequest), response: *rpc.Response(otlp.ExportTraceServiceResponse)) ?connect.RpcError {
    const spans = count_spans(&request.message) catch return .{ .code = .invalid_argument, .message = "the request holds too many resources or scopes" };
    const kept = proto.encode(otlp.ExportTraceServiceRequest, &request.message, room.kept[room.kept_len..]) catch {
        room.rejected += spans;
        response.message.partial_success = .{ .rejected_spans = @intCast(spans), .error_message = "the receiver keeps no more spans" };
        return null;
    };
    room.kept_len += kept.len;
    room.taken += spans;
    return null;
}

/// Answers with every request `Export` kept, as one request.
fn received_in(room: *Room, decoder: *const proto.Decoder, response: *rpc.Response(otlp.ExportTraceServiceRequest)) ?connect.RpcError {
    std.debug.assert(room.kept_len <= constants.kept_len_max);
    response.message = decoder.decode(otlp.ExportTraceServiceRequest, room.kept[0..room.kept_len]) catch {
        return .{ .code = .internal, .message = "the kept requests do not decode" };
    };
    return null;
}

/// The spans of every scope of every resource of `request`.
pub fn count_spans(request: *const otlp.ExportTraceServiceRequest) (Error || proto.Error)!u64 {
    var total: u64 = 0;
    var resources = request.resource_spans.iterator();
    for (0..constants.resources_max + 1) |_| {
        const resource = try resources.next() orelse return total;
        var scopes = resource.scope_spans.iterator();
        for (0..constants.scopes_max + 1) |_| {
            const scope = try scopes.next() orelse break;
            total += try scope.spans.count();
        } else return error.ScopesTooMany;
    }
    return error.ResourcesTooMany;
}
