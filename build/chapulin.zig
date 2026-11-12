//! The chapulin object the `oidc` module links (docs/decisions.md entry 34).
const std = @import("std");
const assert = std.debug.assert;

/// colibri's own request for its TCP object on a host target, key for key (colibri's
/// `build/modules_chapulin.zig`, and its docs/usage.md, "Naming chapulin beside colibri"). Zig
/// keys a dependency by its package and its options, so the two requests give one object. A
/// request that differs in one value builds a second object, which defines every public name
/// again, and the link fails with a duplicate symbol. So a release of colibri that changes its
/// request changes this one. chapulin refuses `JWS=on` off a host target, so the caller asks
/// `host_object` first.
pub fn object(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Dependency {
    assert(host_object(target));
    return b.dependency("chapulin", .{
        .target = target,
        .RAND = .session,
        .TRANSPORT = .@"tcp-nonblocking",
        .ROLE = .both,
        .TRUST = .webpki,
        .EXPORTER = .on,
        .SUITE = .aesgcm,
        .TX_RECORD = "16384",
        .KEYLOG = .off,
        .DNSSEC = .on,
        .JWS = .on,
        .SCRAM = .on,
    });
}

/// chapulin's host test (its build's `hostTarget`): a little-endian arm64 target with NEON, or an
/// x86-64 target with SSE2. Its RS256 check runs on a host object alone (chapulin's `jws.h`).
pub fn host_object(target: std.Build.ResolvedTarget) bool {
    const cpu = target.result.cpu;
    return switch (cpu.arch) {
        .aarch64 => std.Target.aarch64.featureSetHas(cpu.features, .neon),
        .x86_64 => std.Target.x86.featureSetHas(cpu.features, .sse2),
        else => false,
    };
}
