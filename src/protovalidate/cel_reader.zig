//! The CEL reader as a program runs it: the grammar of `cel/cel_grammar.zig` over a tree in
//! storage that its caller passes, and the tree's text.
//!
//! It is no part of `protovalidate`'s API. A schema's rules are compiled, and no program reads
//! an expression as it runs. The build gives this file as the module `cel_reader` to the checks
//! of tools/ alone: `tools/cel_vectors/replay.zig` reads with it the expressions that the Lean
//! model wrote from a seed, so that check runs the grammar the compiler runs (spec/README.md).
const files = struct {
    const tree = @import("cel/cel_tree.zig");
};

/// A tree in the caller's storage, which holds any tree a text of the storage's length gives.
pub const Tree = files.tree.Tree;
pub const Item = files.tree.Item;
pub const Index = files.tree.Index;
/// What a text gives: the place of its tree's root, or what is wrong with it.
pub const Parsed = files.tree.Parsed;
/// How a tree's text writes a double: its value, or its text in the expression.
pub const Doubles = files.tree.Doubles;
pub const parse = files.tree.parse;
pub const write = files.tree.write;

test "the reader's root exports the names the checks call" {
    try @import("public_names").expect(@This(), &.{ "Tree", "Item", "Index", "Parsed", "Doubles", "parse", "write" });
}
