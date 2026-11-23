# Validating messages

The `protovalidate` module checks a message against the
[protovalidate](https://github.com/bufbuild/protovalidate) rules of its schema. The plugin writes
the rules beside each message, and the module compiles them with your program: no rule is read
at run time, no expression is interpreted, and the module allocates nothing. It passes all 2872
cases of protovalidate's conformance suite.

## Rules in your schema

The `protovalidate` module checks a message against the rules its schema states with
[protovalidate](https://github.com/bufbuild/protovalidate)'s options:

```proto
import "buf/validate/validate.proto";

message User {
  string email = 1 [(buf.validate.field).string.email = true];
  int32 age = 2 [(buf.validate.field).int32 = {gte: 18, lt: 150}];
  repeated string tags = 3 [(buf.validate.field).repeated = {max_items: 8, unique: true}];
}
```

## Validate a message

The plugin writes the rules beside each message, as a table that `validate` reads when your
program compiles ([decision 47](decisions.md)). No rule is read or parsed at run time, and the module allocates
nothing: your program passes the report's storage.

```zig
const protovalidate = @import("protovalidate");
const codec = @import("codec");

// Once, as the program starts: the CPU features a rule's regular expression may use.
const cpu_features: codec.Features = .detect();

var storage: [protovalidate.constants.report_bytes_default]u8 align(@alignOf(protovalidate.Violation)) = undefined;
var report: protovalidate.Report = .init(&storage);
protovalidate.validate(User, &user, .{ .cpu_features = cpu_features }, &report) catch |failure| switch (failure) {
    // Each violation is a `buf.validate.Violation`: the field's path, the rule's path, the
    // rule's id, such as "string.email", and a message.
    error.Invalid => for (report.violations()) |violation| {
        std.debug.print("{s}: {s}\n", .{ violation.rule_id.?, violation.message.? });
    },
    else => return failure,
};
```

Import it as `connect_zig.module("protovalidate")`, and give a generated file that holds rules
the same module: its header names it. A message with no rule keeps the code it had. `validate`
checks `required`, `ignore`, a oneof's `required`, a message's `oneof` rules and each type's
standard rules, and walks nested messages, repeated fields and maps. A rule that reads the time,
such as `timestamp.lt_now`, takes it from `.{ .now = ... }`. A rule's regular expression
searches with the CPU features in `.cpu_features`, stdx's `codec.Features`. The module probes no
CPU, so your program calls `codec.Features.detect()` once as it starts. `codec` is stdx's: name
stdx in your `build.zig.zon` at the commit connect-zig pins as `stdx_regex`, and pass it
connect-zig's options, so its `codec` is the module protovalidate imports.
`codec.Features.target()` names what the build target guarantees, and `codec.Features.none()`
keeps each search on its plain path.
`report.encode` writes the violations as a `buf.validate.Violations`, which an error carries as
a detail.

## Validate each request

A server checks each request with `protovalidate.Interceptor`. A route calls an interceptor's
`on_message` with each request message once it is decoded, before the handler takes it: a unary
call's one message, and each message of a stream.

```zig
const validation: protovalidate.InterceptorOptions = .{};

// What each call keeps for itself: what the error of a refused message points to.
pub const Values = struct {
    protovalidate: protovalidate.InterceptorRoom(connect, validation) = .{},
};

const Validate = protovalidate.Interceptor(connect, Values, validation);

pub const route_options: rpc.RouteOptions = .{ .interceptors = &.{Validate} };
```

The route table names `Values` as its `.Values`. A message that breaks a rule ends its call with
`invalid_argument`. The error's message names the first violation, such as "email: must be a
valid email address (and 1 more)", and its detail is a `buf.validate.Violations` that holds each
one. A message type with no rule costs its call no instruction. The interceptor takes the
`connect` module as a parameter, because `protovalidate` imports none. It reads the CPU features
from a field `cpu_features: codec.Features` of your `App`, which your
program sets once as it starts, and the time from a field `protovalidate_now`. An `App` with no
`cpu_features` stops the build.
[examples/validate](../examples/validate) serves a service behind it.

The interceptor reads every list of a request, so give its route the storage the decoded
request takes. A route decodes a binary request's lists into `storage_bytes` of
`connect_colibri.RouteOptions`, which defaults to 4 times `message_bytes` (decision 37). A
decoded list takes more room than its octets. A list that does not fit stays in the message,
and the interceptor decodes it a second time. An OTLP export of 512 spans, 233 KB, takes about
850 KB decoded. In 256 KiB, validation cost the OTLP sink 0.96 µs a span; in 1 MiB, it cost
0.16 µs. Give your context a field `messages_past_storage: u64` to count the requests that did
not fit, and `zig build otlp-validate-cost` times validation by the size of the storage.

## CEL rules

A schema's own rules are CEL expressions, in `cel` and `cel_expression`:

```proto
message Booking {
  option (buf.validate.message).cel = {
    id: "booking.ordered"
    message: "check_in must be before check_out"
    expression: "this.check_in < this.check_out"
  };
  google.protobuf.Timestamp check_in = 1;
  google.protobuf.Timestamp check_out = 2;
  repeated string guests = 3 [(buf.validate.field).cel_expression = "this.all(g, g.size() > 0)"];
}
```

The module compiles each expression when your program compiles, from the text the table holds
([decision 47](decisions.md)). It reads the expression, gives each part a type from the message's fields, and
unfolds it into plain code, so no interpreter and no expression's tree exist at run time. It
reads CEL's operators, conditionals, field selection, `has`, `dyn`, lists and maps with `in`,
`size`, an index and the macros `all`, `exists` and `exists_one`, the conversions, the string
functions, and protovalidate's own functions, such as `isEmail` and `isIpPrefix`.

- An expression that does not parse, names a field its message lacks, or calls a function with
  the wrong types stops your build, with a message that names the expression.
- An expression that fails as it runs, such as by a division by zero, ends `validate` with
  `error.Unevaluable`: the rule gave no verdict.
- An expression reads at most `constants.cel_steps_max` elements of lists and maps, so a macro
  inside a macro cannot make a small message cost much.

## Predefined rules

A predefined rule is an extension of one of validate.proto's rule messages, which states its
CEL rules once for every field that sets it:

```proto
extend buf.validate.Int32Rules {
  bool even = 1161 [(buf.validate.predefined).cel = {
    id: "int32.even"
    message: "must be even"
    expression: "!rule || this % 2 == 0"
  }];
}

message Order {
  int32 quantity = 1 [(buf.validate.field).int32.(even) = true];
}
```

The plugin reads each extension from its request and writes its value and its rules into the
table of the message that sets it. An expression reads the field as `this`, the extension's
value as `rule` and the rule message as `rules`. A value is a scalar, a wrapper such as
`google.protobuf.Int64Value`, or a list of them.

## Patterns

`pattern` and CEL's `matches` take RE2's syntax, on stdx's regular expressions: named groups,
Unicode's properties such as `\p{Greek}`, and `(?i)` past ASCII, from Unicode 17.0.0. The
compiler reads each pattern once, so the pattern of `matches` is a string literal, and a
pattern stdx refuses, such as one with a backreference, which RE2 refuses too, stops your
build.

## Messages from `format`

A rule's message may come from CEL's `format`, as in `'not a valid path: %s'.format([this])`.
The text and the list are literals, and the conversions `%s`, `%d`, `%x` and `%X` are read.
The text is written into the report's storage, so a report needs room for it.

## What stops the build

A rule the module has no check for stops your build, with a message that names it. That holds
today for a predefined rule whose value is a message that is no wrapper, and for the parts of
CEL the module does not read: a zone's name, such as `America/Los_Angeles`, in a `get`
function of a timestamp. The module reads `UTC` and fixed offsets such as `+05:30`, and no
time zone database.

`+` of two strings and `string(number)` write their text into the report's storage, as
`format` does, so a report needs room for it. Text that the expression no longer needs is
given back as it runs.

`filter` and `map` work on any list or map. The list they give is computed as you read it,
so it takes no memory, and reading it twice computes it twice.

A list literal, `[1, 2]`, and a map literal, `{'a': 1, 'b': 2}`, may hold elements of two
types, such as `[1, 'a']`, and a map's keys are ints, uints, bools or strings. `[]` and `{}`
are a list and a map of any type. `==` compares two lists element by element, and two maps key
by key, so `this.labels == {'env': 'prod'}` reads. An index into a list of two element types
takes a place your build knows, such as `[1, 'a'][0]`, and `filter` and `map` take no such
list, because their result would have no one type.

## How it follows CEL

The CEL rules follow the [CEL language definition](specs/cel/langdef.md), which the tree
holds as cel-spec published it, and each rule in the code cites its section.
[specs/README.md](specs/README.md) lists where the definition is silent or gives two
readings, where the module follows cel-go, and where it differs from cel-go on purpose.

An expression has the verdict that protovalidate-go gives it, which runs cel-go: `==` takes
two values of one type, a conversion of a literal that fails, such as `int('x')`, stops your
build, and one `-` before a number is the number's sign. `tools/cel_differential_check.sh`
compares the two libraries on random rules and random messages.

## Compile time and limits

A large schema compiles in time that grows with its rules, about 7.5 ms for each CEL
expression in a Debug build on one core of a 2.1 GHz Xeon: a message of 2,000 fields with
2,003 expressions built in 21 s, and 100 messages with 2,300 expressions in 20 s. With
standard rules alone, the second schema built in 3 s. A check written by hand costs the
compiler 0.17 ms, so a rule cannot cost less: [docs/performance.md](performance.md),
"The compiler's time", says where the rest goes. A message can have any number of repeated and
map fields: `tools/wide` has one with 1,100.

## Speed

One decode of a request message and one validation of it against the rules of
its schema, beside protovalidate-go, protovalidate-es on Node.js, protovalidate-buffa and
prost-protovalidate. From CI's [run 242](https://github.com/c4milo/connect-zig/actions/runs/45085140006), on an AMD EPYC 9V74 core: connect-zig is 12 to
58 times as fast as protovalidate-go, and the fastest of the five in all six cases. On a
Neoverse-N2 core, arm64, it is 14 to 68 times as fast, and the fastest in all six too.
[benchmarks.md](benchmarks.md), "Validation", holds the tables and says how it is measured.

![Bars of the speed of a decode with a validation through connect-zig, protovalidate-buffa, prost-protovalidate and protovalidate-es, in multiples of protovalidate-go's, on x86-64: connect-zig is 12 to 58 times as fast as protovalidate-go and the fastest in 6 of 6 cases](images/validate-vs-go.svg)

![Bars of the speed of a decode with a validation through connect-zig, protovalidate-buffa, prost-protovalidate and protovalidate-es, in multiples of protovalidate-go's, on arm64: connect-zig is 14 to 68 times as fast as protovalidate-go and the fastest in 6 of 6 cases](images/validate-vs-go-arm64.svg)

## How it is checked

- `tools/protovalidate_conformance_check.sh` runs [protovalidate's conformance
  harness](https://github.com/bufbuild/protovalidate/blob/main/docs/conformance.md) v1.2.2, with
  strict messages and strict errors. All 2872 of its cases pass.
- `tools/lean_check.sh` builds a [Lean model](../spec/README.md) of the CEL syntax, written
  from the CEL language definition, and requires the vector file beside the Zig grammar to be
  what the model gives. A unit test reads each of the 6,671 expressions with the grammar the
  compiler runs, and requires the model's tree or its refusal. No theorem is proved yet. The
  script then draws 10,000 expressions from a new seed, gives each to the model and to the
  Zig grammar, and requires the same tree: on five seeds, 50,000 expressions were read alike.
- `tools/cel_differential_check.sh` writes random CEL rules and random messages from a seed,
  and requires this library and
  [protovalidate-go](https://github.com/bufbuild/protovalidate-go) v1.4.1, which runs cel-go,
  to give each message the same verdict under each rule: valid, invalid with the same
  message, a failure as the rule runs, or a rule that does not compile. On six seeds, 60,000
  verdicts of 1,500 rules were the same. Its first runs found six differences, which
  [decision 47](decisions.md) lists.
- `tools/cel_conformance_check.sh` runs [cel-spec's conformance
  suite](https://github.com/google/cel-spec/tree/v0.25.3/tests/simple) v0.25.3 over the code a
  rule's expression compiles into: each of its 1,819 tests that declare no variables and build
  no message. 1,174 pass. 614 test an extension that protovalidate does not turn on, or a part
  of the language this library does not build, such as a message literal; `known.txt` beside the
  script gives the reason for each. 28 turn the type check off, which a rule always has. Its
  first run found four differences, which [decision 47](decisions.md) lists.
- `tools/compile_time_check.sh` holds what a schema's CEL rules cost the compiler to a
  baseline, and unit tests hold the compiler's reading and typing of an expression to a count
  of branches.
- `zig build test-protovalidate -Drelease --fuzz=<runs>` runs Zig's fuzzer over that grammar:
  a parse depends on its text alone, and a tree's text reads back as the same tree.
