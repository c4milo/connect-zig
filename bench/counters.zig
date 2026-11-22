//! Hardware counters through Linux's perf_event_open, in user space alone: the cycles,
//! instructions, branches and branch misses of the code a benchmark counts (`bench-validate
//! --counters`). A host that is not Linux has none, which `available` says at comptime. A Linux
//! host may refuse them, as a virtual machine with no counters does, and `Counters.open` says so.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// Whether this host can have the counters at all.
pub const available = builtin.os.tag == .linux;

/// The counters, as perf_event_open numbers them, in the order of `Counters.stop`'s counts.
pub const events = [_]linux.PERF.COUNT.HW{ .CPU_CYCLES, .INSTRUCTIONS, .BRANCH_INSTRUCTIONS, .BRANCH_MISSES };
pub const cycles = 0;
pub const instructions = 1;
pub const branches = 2;
pub const branch_misses = 3;

pub const Counters = struct {
    fds: [events.len]i32,

    /// Opens each counter for this thread, disabled, in user space alone. A refusal names the
    /// counter and the kernel's answer.
    pub fn open(refusal: *[]const u8) error{Unavailable}!Counters {
        var counters: Counters = undefined;
        for (events, &counters.fds) |event, *fd| {
            var attr: linux.perf_event_attr = .{
                .type = .HARDWARE,
                .config = @intFromEnum(event),
                .flags = .{ .disabled = true, .exclude_kernel = true, .exclude_hv = true },
            };
            const result = linux.perf_event_open(&attr, 0, -1, -1, linux.PERF.FLAG.FD_CLOEXEC);
            if (linux.errno(result) != .SUCCESS) {
                refusal.* = @tagName(linux.errno(result));
                return error.Unavailable;
            }
            fd.* = @intCast(result);
        }
        return counters;
    }

    pub fn start(counters: *const Counters) void {
        for (counters.fds) |fd| _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.RESET, 0);
        for (counters.fds) |fd| _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.ENABLE, 0);
    }

    pub fn stop(counters: *const Counters) [events.len]u64 {
        for (counters.fds) |fd| _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.DISABLE, 0);
        var counts = [_]u64{0} ** events.len;
        for (counters.fds, &counts) |fd, *count| {
            var octets = [_]u8{0} ** @sizeOf(u64);
            // The kernel writes each count in the host's order.
            count.* = if (linux.read(fd, &octets, octets.len) == octets.len) std.mem.readInt(u64, &octets, builtin.cpu.arch.endian()) else 0;
        }
        return counts;
    }
};
