//! The chapulin object the `oidc` module links (docs/decisions.md entry 34).
const std = @import("std");
const assert = std.debug.assert;

/// colibri's request for its TCP object (colibri's `build/modules_chapulin.zig`), with `JWS=on`
/// beside it. A program that links colibri and `oidc` links one chapulin object only when the two
/// requests and the two pins are equal: one different option builds a second object, which
/// defines every public name again. chapulin refuses `JWS=on` off a host target, so the caller
/// asks `host_object` first.
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
