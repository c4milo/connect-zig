//! A client call of `connect_colibri` with the buffers it writes and reads in. A program keeps
//! each call in its state (decision 42), so the call and its buffers stay in place until the
//! round ends.
const connect = @import("connect_zig").connect;
const rpc = @import("connect_zig").connect_colibri;
const CallBuffers = @import("client_side.zig").CallBuffers;

pub fn Call(comptime method: connect.Method, comptime options: rpc.ClientCallOptions) type {
    return struct {
        const Self = @This();

        call: rpc.ClientCall(method, options),
        buffers: CallBuffers,

        /// Builds a call that sends `messages` whole, with `client`, which the program made once
        /// (decision 51). Its interceptors' hooks get `context` first (decision 44).
        pub fn init(self: *Self, client: *const connect.Client, context: options.Context, call_options: *const connect.client.Options, messages: []const method.Request) !void {
            try self.call.init(client, context, call_options, messages, &CallBuffers.of(&self.buffers));
        }

        /// Builds a call whose `Sender` streams each message.
        pub fn init_stream(self: *Self, client: *const connect.Client, context: options.Context, call_options: *const connect.client.Options) !void {
            try self.call.init_stream(client, context, call_options, &CallBuffers.of(&self.buffers));
        }
    };
}
