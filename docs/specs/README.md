# The specifications the code cites

Each file of this folder is a specification as its publisher wrote it, with no change.
`SHA256SUMS` holds each file's checksum, and `tools/citations_check.sh` checks them. The lint
reads no file of this folder.

| File | What it is | What the code reads it for |
| --- | --- | --- |
| `cel/langdef.md` | The CEL language definition: `doc/langdef.md` of [google/cel-spec](https://github.com/google/cel-spec) at tag v0.25.3, commit `ba58ae5007845f3a1279b488cdeb79645ce958bb`. cel-go v0.33.2 builds on that release, and protovalidate-go v1.4.1 runs that cel-go. | The CEL rules of `protovalidate` (decision 47): the lexis and the grammar, the types, the checks of types, the operators, the macros and the functions. |
| `cel/LICENSE` | The license of cel-spec, Apache 2.0. | The terms of the copy. |

protovalidate's own rules are in `src/protovalidate/proto/buf/validate/validate.proto`, which
`tools/protovalidate_conformance_check.sh` holds to its release.

## How the code cites the CEL language definition

A comment on the line that does a check names the section that states the rule: `CEL language
definition, "Equality"`. The name is a heading of `cel/langdef.md`. A rule of the lexis or of
the grammar quotes its production, as `"INT_LIT ::= -? DIGIT+"`, and its section is "Syntax".
`tools/citations_check.sh` requires each cited name to be a heading of the file.

Read the section before a change to the code that cites it, and cite the section in the code
that a new rule adds.

## Where the code follows cel-go and not the definition

protovalidate's libraries run cel-go, and `tools/cel_differential_check.sh` holds this module's
verdicts to protovalidate-go's. Where the definition is silent, or gives a text two readings,
the module takes cel-go's answer, and the code says so where it does:

- A run of "-" before a number. "INT_LIT ::= -? DIGIT+" makes the sign a part of the literal,
  and "Unary" takes a run of "-" too. cel-go reads one "-" as the sign, and a run of two or more
  as negations of a number with no sign (`cel_grammar.zig`).
- `uint` of a double below zero. "Types and Conversions" says "rounds toward zero, errors if
  out of range", and not whether -0.5 is in range. cel-go takes no double below zero
  (`cel_function.zig`).
- A conversion of a literal that fails, such as `int('x')`. The definition makes it a failure
  as the expression runs. cel-go computes a conversion of a constant once, before the
  expression runs, and protovalidate-go refuses the rule. The module stops the build
  (`cel_check.zig`).
- The text of a duration. "Types and Conversions" lists the suffixes and gives examples, and no
  grammar. cel-go reads the text with Go's `time.ParseDuration` (`cel_time.zig`).
- The words `bool(string)` takes. The definition's examples are "true" and "FALSE". cel-go
  takes the words of Go's `strconv.ParseBool` (`cel_function.zig`).
- An order of two numbers of different types. "Ordering" gives it as an expression runs, and
  "Comparison Operators" declares no such overload for the checker. protovalidate's CEL
  environment declares them, with cel-go's `CrossTypeNumericComparisons` (`cel_value.zig`).

Two places differ from cel-go in the regular expressions of `matches`, which follow RE2 and
stdx's `regex` (decision 47):

- An octet that is not UTF-8. RE2 and stdx match no such octet. Go's regexp, which cel-go
  runs, reads it as U+FFFD. A string field of proto3 holds no such octet, since its decode
  refuses one.
- A form that stdx refuses: `\p{...}`, `\C`, and `(?i)` over a letter past ASCII. Such a
  pattern stops the build, as a pattern that is no literal does.

One place follows neither. Behind `dyn` the module marks each part that came through `dyn` as
dynamic, where "Gradual Type Checking" and cel-go give the result of a function its declared
type. So the module compiles `dyn(x).size() == 'a'`, which cel-go refuses (decision 47).
