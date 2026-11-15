//! Compiles the generated code of the example's schemas. No program reads the messages of
//! large.proto, so this test is what compiles them.
const std = @import("std");

test "the generated code of each schema compiles" {
    std.testing.refAllDecls(@import("kitchen_v1_shared"));
    std.testing.refAllDecls(@import("kitchen"));
    std.testing.refAllDecls(@import("large"));
}
