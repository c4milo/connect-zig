//! `Client`: what the calls of one program share. A program makes one as it starts, with the CPU
//! features it detected and the codecs it placed, and makes each call with it from then on, as a
//! program makes each request with its `std.http.Client` (decision 51). What differs from call
//! to call is in `Options`.
//!
//! It is no HTTP client: it opens no connection and sends no request. The program's HTTP
//! library does both, colibri's connection pool or another, with the request this client builds.
const platform = @import("stdx").platform;
const compression = @import("compression.zig");
const client_call = @import("client_call.zig");
const client_response = @import("client_response.zig");

pub const Client = struct {
    /// The CPU features the client writes each request and reads each response with: the
    /// program's, which it detects once, as it starts, with stdx's `platform.CpuFeatures.detect`.
    /// The module probes no CPU and names none for the program (decision 10 as amended).
    cpu_features: platform.CpuFeatures,
    /// The encoders the client compresses requests with. A call's `Options.request_coding` names
    /// one of them, or identity.
    encoders: compression.Encoders = .{},
    /// What the client decompresses, which each request names in its accept header.
    decoders: compression.Decoders = .{},

    /// Builds the request of a call of `method` that sends `messages`.
    pub const request = client_call.request;
    /// Writes one message of a streamed request, in its envelope.
    pub const write_message = client_call.write_message;
    /// Starts the read of a call's response.
    pub const response = client_response.start;
};
