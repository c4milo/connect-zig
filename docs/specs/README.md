# The specifications the code cites

Each file of this folder is a specification as its publisher wrote it, with no change.
`SHA256SUMS` holds each file's checksum, and `tools/citations_check.sh` checks them. The lint
reads no file of this folder.

| File | What it is | What the code reads it for |
| --- | --- | --- |
| `cel/langdef.md` | The CEL language definition: `doc/langdef.md` of [google/cel-spec](https://github.com/google/cel-spec) at tag v0.25.3, commit `ba58ae5007845f3a1279b488cdeb79645ce958bb`. cel-go v0.33.2 builds on that release, and protovalidate-go v1.4.1 runs that cel-go. | The CEL rules of `protovalidate` (decision 47): the lexis and the grammar, the types, the checks of types, the operators, the macros and the functions. |
| `cel/strings.md` | The CEL strings extension: `doc/extensions/strings.md` of the same cel-spec commit. | `format`, which protovalidate's libraries turn on and the messages of its predefined rules call: its text, its conversions and the text each type takes. |
| `cel/LICENSE` | The license of cel-spec, Apache 2.0. | The terms of the copy. |

protovalidate's own rules are in `src/protovalidate/proto/buf/validate/validate.proto`, which
`tools/protovalidate_conformance_check.sh` holds to its release. `tools/cel_conformance_check.sh`
runs the conformance suite of the same cel-spec commit, and requires the two files of `cel/` to
be that commit's.

## How the code cites the CEL language definition

A comment on the line that does a check names the section that states the rule: `CEL language
definition, "Equality"`. The name is a heading of `cel/langdef.md`. A rule of the lexis or of
the grammar quotes its production, as `"INT_LIT ::= -? DIGIT+"`, and its section is "Syntax".
`tools/citations_check.sh` requires each cited name to be a heading of the file. A citation of
`cel/strings.md` reads `CEL strings extension, "Conversion"` the same way.

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
- A conversion of a constant that fails, such as `int('x')` or `uint(double(-100))`. The
  definition makes it a failure as the expression runs. protovalidate-go builds its programs
  with cel-go's `OptOptimize`, which computes each type conversion of a constant once, before
  the expression runs, from the inside out, and refuses the rule when one fails. The module
  stops the build (`cel_constant.zig`).
- The text of a duration. "Types and Conversions" lists the suffixes and gives examples, and no
  grammar. cel-go reads the text with Go's `time.ParseDuration` (`cel_time.zig`).
- The words `bool(string)` takes. The definition's examples are "true" and "FALSE". cel-go
  takes the words of Go's `strconv.ParseBool` (`cel_function.zig`).
- The text of a timestamp. "timestamp" says "according to RFC3339". cel-go reads it with Go's
  `time.Parse(time.RFC3339, ...)`, which takes a fraction of any length and counts its first
  nine digits, and refuses a lower-case `t` or `z` (`cel_timestamp.zig`).
- A zone's offset. "Timezones" gives `("+" | "-") Digit Digit ":" Digit Digit`. cel-go reads
  hours from -23 to 23 and minutes from 0 to 59, each an int that may have a sign, so it takes
  `5:00` and `05:+30` too (`cel_timestamp.zig`).
- `getMilliseconds` of a duration. "getMilliseconds" gives "the milliseconds portion", as in
  `duration("1.234s").getMilliseconds() // 234`. cel-go gives all the milliseconds, 1234, and
  so does the module. getHours, getMinutes and getSeconds round as Go's `Hours()`,
  `Minutes()` and `Seconds()` do, which may round a sum up to the next unit
  (`cel_duration.zig`).
- A duration past an int64 of nanoseconds, in a message. protobuf-go's `AsDuration` gives
  cel-go the greatest or the least duration, and so does the module (`cel_duration.zig`). A
  duration whose seconds and nanoseconds have unlike signs is their sum, so -3s and 0.5s
  equal -2.5s (`cel_value.zig`).
- The least int's remainder by -1. "Overflow" makes an operation fail when "the results exceed
  the range", and the remainder, 0, does not. cel-go fails it, as the division it would take
  overflows (`cel_number.zig`).
- `string` of a double and of a uint. "string" says only that it "converts a double to a
  string". cel-go writes it as Go's `strconv.FormatFloat(d, 'g', -1, 64)` does: `1.5`, `1e+06`,
  `+Inf`. The section's example gives `string(123u)` as `"123u"`, and its text gives a uint's
  "base 10 representation". cel-go writes `123` (`cel_text.zig`).
- An order of two numbers of different types. "Ordering" gives it as an expression runs, and
  "Comparison Operators" declares no such overload for the checker. protovalidate's CEL
  environment declares them, with cel-go's `CrossTypeNumericComparisons` (`cel_value.zig`).
- An order of a double and an integer. "Numbers" puts the numbers on "a continuous number
  line". cel-go compares a double within the integer type's range with the integer made a
  double, which rounds an integer past 2^53, so `dyn(9223372036854775807) >=
  9223372036854775808.0` is true. cel-spec's conformance suite expects cel-go's answer
  (`cel_number.zig`).
- A list's index behind `dyn`. "List Operators" gives `list(A)[int] -> A`. cel-go also takes a
  uint and a double with no fraction (`cel_collection.zig`).
- `%%` in the text of `format`. The strings extension names no such conversion. cel-go writes
  one `%`, as cel-spec's conformance suite expects (`cel_format.zig`).

Two places differ from cel-go in the regular expressions of `matches`, which follow RE2 and
stdx's `regex` (decision 47):

- An octet that is not UTF-8. RE2 and stdx match no such octet. Go's regexp, which cel-go
  runs, reads it as U+FFFD. A string field of proto3 holds no such octet, since its decode
  refuses one.
- A form that stdx refuses: `\p{...}`, `\C`, and `(?i)` over a letter past ASCII. Such a
  pattern stops the build, as a pattern that is no literal does.

Two places follow the specification and not cel-go:

- `%s` of bytes that are not UTF-8, in `format`: the CEL strings extension, `cel/strings.md`,
  replaces each run of such octets with one U+FFFD, and cel-go copies them as they are. A
  violation's message is then always UTF-8.
- `string` of a timestamp. A CEL timestamp is a `google.protobuf.Timestamp`, which holds no
  zone, so the module writes it in UTC. cel-go keeps the offset that a timestamp's text gave,
  and writes `timestamp('2023-12-25T01:00:00+01:00')` with `+01:00` (`cel_timestamp.zig`).

One place differs from cel-go because the module reads no file: a zone's name, such as
`America/Los_Angeles` or `GMT`. cel-go loads it from the IANA time zone database. The module
reads `UTC` and fixed offsets alone. A literal name stops the build, and a name from a field
fails the expression as it runs (decision 47).

One place follows neither. Behind `dyn` the module marks each part that came through `dyn` as
dynamic, where "Gradual Type Checking" and cel-go give the result of a function its declared
type. So the module compiles `dyn(x).size() == 'a'`, which cel-go refuses (decision 47).
