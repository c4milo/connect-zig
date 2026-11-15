//! A client call of `connect_colibri` with the buffers it writes and reads in. A program keeps
//! each call in its state (decision 42), so the call and its buffers stay in place until the
//! round ends.
const connect = @import("connect");
const rpc = @import("connect_colibri");
const CallBuffers = @import("client_side.zig").CallBuffers;

pub fn Call(comptime method: connect.Method, comptime options: rpc.ClientCallOptions) type {
    return struct {
        const Self = @This();

        call: rpc.ClientCall(method, options),
        buffers: CallBuffers,

        /// Builds a call that sends `messages` whole.
        pub fn init(self: *Self, call_options: *const connect.client.Options, messages: []const method.Request) !void {
            try self.call.init(call_options, messages, &CallBuffers.of(&self.buffers));
        }

        /// Builds a call whose `Sender` streams each message.
        pub fn init_stream(self: *Self, call_options: *const connect.client.Options) !void {
            try self.call.init_stream(call_options, &CallBuffers.of(&self.buffers));
        }
    };
}
