//! What the protobuf module's tests share: one `Decoder` and one `Encoder`, with the build
//! target's CPU features. A program passes the features it detected once; the tests run every
//! path the build target has.
const platform = @import("stdx").platform;
const Decoder = @import("decoder.zig").Decoder;
const Encoder = @import("encoder.zig").Encoder;

/// The CPU features the tests run with: the build target's.
pub const cpu_features = platform.CpuFeatures.target();
pub const decoder: Decoder = .init(cpu_features);
pub const encoder: Encoder = .init(cpu_features);
