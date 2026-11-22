//! A CEL expression compiled alone, outside a rule: the typing and the code of `cel/`, with the
//! values the code gives.
//!
//! It is no part of `protovalidate`'s API: a schema's rules are compiled, and a program names
//! no expression of its own. The build gives this file as the module `cel_expression` to the
//! checks of tools/ alone: `tools/cel_conformance/runner.zig` runs with it the expressions of
//! cel-spec's conformance suite, so that check runs the code that a rule's expression compiles
//! into (`tools/cel_conformance_check.sh`).
const files = struct {
    const program = @import("cel/cel_program.zig");
    const types = @import("cel/cel_type.zig");
    const list = @import("cel/cel_list.zig");
    const mixed = @import("cel/cel_mixed.zig");
    const type_value = @import("cel/cel_type_value.zig");
};

/// The names an expression may read, and the type of each one's value.
pub const Scope = files.types.Scope;
/// What an expression reads beside its names: `now`, the room it writes text into, and its
/// count of steps.
pub const Env = files.types.Env;
pub const Text = files.types.Text;
pub const Error = files.types.Error;
/// The types of the values an expression gives that are no Zig type of their own.
pub const Bytes = files.types.Bytes;
pub const Null = files.types.Null;
pub const TypeValue = files.type_value.TypeValue;
/// What stops an expression from compiling for a scope, or null; the type of its value; and
/// its value for one value of each name.
pub const problem_of = files.program.problem_of;
pub const Type = files.program.Type;
pub const run = files.program.run;
/// Whether a type is a list or a map, and the iterator of a list's elements.
pub const is_list = files.list.is_list;
pub const is_map = files.list.is_map;
pub const iterate = files.list.iterate;
/// Whether a type is a list or a map literal whose elements are of two types or more, a tuple.
pub const is_mixed_list = files.mixed.is_mixed_list;
pub const is_mixed_map = files.mixed.is_mixed_map;

test "the expression's root exports the names the checks call" {
    try @import("public_names").expect(@This(), &.{ "Scope", "Env", "Text", "Error", "Bytes", "Null", "TypeValue", "problem_of", "Type", "run", "is_list", "is_map", "iterate", "is_mixed_list", "is_mixed_map" });
}
