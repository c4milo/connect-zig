//! The cognitive-complexity score, over the paths build/lint.zig passes. The threshold comes
//! from there too, so this entry point forwards to pepegrillo's tool and configures nothing.
const std = @import("std");
const pepegrillo = @import("pepegrillo");

pub fn main(init: std.process.Init) !void {
    return pepegrillo.complexity.main(init);
}
