# The Lean model

This folder holds a Lean 4 model of the CEL syntax that `protovalidate` reads: its lexis, its
grammar and the text of a tree. The Zig grammar in `src/protovalidate/cel/` is checked against
it.

## What the model is

- `Cel/Lexis.lean`: the tokens of an expression, from the CEL language definition, "Syntax":
  `IDENT`, `INT_LIT`, `UINT_LIT`, `FLOAT_LIT`, `STRING_LIT`, `BYTES_LIT`, `ESCAPE`, `WHITESPACE`
  and `COMMENT`.
- `Cel/Grammar.lean`: the grammar, one function for each production, from `Expr` down to
  `Primary`. It also states which doubles and which ints a literal holds.
- `Cel/Text.lean`: a tree as an expression with each part in brackets, which reads back as the
  same tree.
- `Vectors.lean`: the program that writes `src/protovalidate/cel/cel_vectors.txt`.

The model follows the language definition, production by production. The Zig grammar reads
the same language another way: one loop for every level of binary operators, and one token
ahead. The two share no code and no structure, so an error in one shows as a difference.

## What the model leaves out

`protovalidate` reads no map literal, no message literal and no name that starts with ".". The
model has none, so a text that holds one has no tree in the model and in the Zig alike.

The Zig grammar refuses an expression whose parts nest more than `cel_depth_max` deep. The
model has no such limit, and no vector nests that deep.

## How the Zig grammar is held to it

`lake exe vectors --write <directory>` writes `cel_vectors.txt`: 6,647 expressions, each with
the text of its tree or "!" for a text that is no expression. The expressions are:

- every sequence of one, two and three tokens of an alphabet of 16;
- every pair of those tokens with no space between them;
- 1,200 sequences of four to nine tokens, and 600 trees, from a fixed generator;
- 223 expressions chosen for the rules of the lexis: each escape, each prefix of a string, the
  ends of each number's range, each keyword and each reserved word.

The unit test "the grammar reads each expression of the Lean model's vectors as the model does"
in `cel_tree_test.zig` reads each expression with the Zig grammar, at run time, and requires
the same tree's text or a problem. The compiler reads an expression with the same grammar
code, and another test requires the two trees to be equal on a corpus.

Before it writes or checks the file, the program requires the model to read the text of each
of its 600 trees back as the tree.

## What is proved

Nothing yet. The model is a definition that Lean accepts as total: each function ends, by a
count of steps that falls. No theorem states a property of the grammar. The check above is a
comparison on 6,647 cases, and Zig's fuzzer holds two more properties on any input: a parse
depends on its text alone, and a tree's text reads back as the tree.

## Commands

- `zig build lean` builds the model and requires `cel_vectors.txt` to be what it gives.
- `zig build lean -- write` rewrites `cel_vectors.txt`.
- `tools/lean_check.sh` runs the first command, and installs the pinned Lean release when no
  `lake` is on the path. `tools/ci.sh` runs it as the check `lean`.

`lean-toolchain` pins the release: Lean 4.34.0.
