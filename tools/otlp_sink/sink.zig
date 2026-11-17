//! The OTLP sink's routes (design §8 step 28): `TraceService/Export` reads each request, counts
//! its spans and drops it, as OpenTelemetry's Collector does with the OTLP receiver and the `nop`
//! exporter. `GET /sink/count` answers with what it took, so the benchmark checks that every call
//! arrived whole.
//!
//! The router decodes each request in full and checks every nested message before `export` runs
//! (decision 6), and `count_spans` decodes each span again. The Collector decodes each request
//! into its own copy of the spans. Both read and check every octet.
const server = @import("server");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const otlp = @import("otlp");
const service = @import("otlp_service");
const constants = @import("constants.zig");

/// What the routes read: the export calls the sink took, and the spans they held.
pub const App = struct {
    codings: rpc.Codings = .{},
    requests: u64 = 0,
    spans: u64 = 0,
};

const route_options: rpc.RouteOptions = .{ .message_bytes = constants.message_bytes };

pub const routes = otlp.TraceService.Routes(rpc, App, Handlers, route_options).routes ++
    .{.{ .get, constants.count_path, Count }} ++
    rpc.Refusals(App, otlp.TraceService.@"export").routes;

const Handlers = struct {
    pub fn @"export"(app: *App, _: *rpc.Context, request: *const rpc.Request(otlp.ExportTraceServiceRequest), _: *rpc.Response(otlp.ExportTraceServiceResponse)) ?connect.RpcError {
        const spans = service.count_spans(&request.message) catch return .{ .code = .invalid_argument, .message = "the request holds too many resources or scopes" };
        app.requests += 1;
        app.spans += spans;
        return null;
    }
};

/// Answers `requests <n> spans <n>`, in text.
const Count = struct {
    pub fn on_request(app: *App, _: *server.RequestContext, _: *void, _: *const server.Request, response: *server.Response) !void {
        try response.header("content-type", "text/plain");
        try response.body().print("requests {d} spans {d}\n", .{ app.requests, app.spans });
        return response.end();
    }
};
