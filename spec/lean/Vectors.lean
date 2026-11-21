import ConnectZig

/-!
# Vectors of the CEL model

Writes, or checks, `cel_vectors.txt` beside the Zig grammar: expressions, each with the text of
the tree the model reads of it, or "!" for a text that is no expression. A Zig unit test
requires the Zig grammar to read each expression as the model does (spec/README.md).

    lake exe vectors (--write | --check) <src/protovalidate/cel directory>
    lake exe vectors --random <seed> <count>

With `--random` the program prints vectors of expressions that it draws from the seed, in the
file's form: `count` sequences of tokens with a space or nothing between two of them, `count`
sequences with spaces, `count` chains of operands and operators with no brackets, and `count`
trees. `tools/lean_check.sh` gives them to the Zig grammar, so each run compares the two on
expressions that no run compared before.

The expressions are every sequence of up to three tokens of a small alphabet, each pair of
those tokens with no space between them, sequences of more tokens that a fixed generator
picks, trees that the same generator builds, and literals that state each rule of the lexis.
Before it writes or checks, the program requires the model to read each tree's text back as
the tree.
-/
open ConnectZig.Cel

/-- An octet in a vector file: itself when it is printable ASCII but "%", and "%" with two
hexadecimal digits when it is any other octet, so a line holds no tab and no line end. -/
def fileOctet (b : UInt8) : String :=
  if 0x20 ≤ b && b ≤ 0x7e && b != 0x25 then String.singleton (Char.ofNat b.toNat)
  else
    let digit (n : Nat) : Char := Char.ofNat (if n < 10 then 0x30 + n else 0x41 + n - 10)
    String.ofList ['%', digit (b.toNat / 16), digit (b.toNat % 16)]

/-- Octets as a vector file holds them. -/
def fileText (octets : Octets) : String := String.join (octets.map fileOctet)

/-- One line: an expression, a tab, and its tree's text or "!". -/
def line (expression : Octets) : String :=
  let result := match parse expression with
    | some tree => fileText (write tree)
    | none => "!"
  fileText expression ++ "\t" ++ result

/-- The tokens of the sequences that hold every order of up to three of them. -/
def small : List String := ["a", "1", "'s'", "(", ")", "[", "]", ".", ",", "?", ":", "-", "!", "+", "<", "in"]

/-- The tokens of the longer sequences. -/
def large : List String :=
  small ++ ["b", "f", "this", "2u", "1.5", "0x1f", "true", "null", "b'x'", "*", "/", "%", "==", "!=", "<=", ">=", ">", "&&", "||",
    "as", "for", "{", "}", "has"]

/-- Every sequence of `n` tokens of `tokens`. -/
def sequences (tokens : List String) : Nat → List (List String)
  | 0 => [[]]
  | n + 1 => (sequences tokens n).flatMap fun rest => tokens.map (· :: rest)

/-- Tokens with one space between them. -/
def spaced (tokens : List String) : Octets := octetsOf (" ".intercalate tokens)

/-- The next state of a generator of fixed numbers: the same numbers on each run. -/
def next (state : Nat) : Nat := (state * 6364136223846793005 + 1442695040888963407) % 2 ^ 64

/-- A number below `bound` from a state. -/
def pick (state bound : Nat) : Nat := (state / 2 ^ 33) % bound

/-- `count` sequences of 4 to 9 tokens of `large`, from `state`. -/
def longer : Nat → Nat → List Octets
  | 0, _ => []
  | count + 1, state =>
    let length := 4 + pick state 6
    let (tokens, state) := (List.range length).foldl
      (fun (acc : List String × Nat) _ =>
        let state := next acc.2
        (large.getD (pick state large.length) "a" :: acc.1, state))
      ([], next state)
    spaced tokens :: longer count (next state)

/-- A tree of at most `depth` parts one inside another, from a state. Each tree is one that
the grammar reads of some expression: a name is no keyword, and a number is in its range. -/
def tree : Nat → Nat → Expr × Nat
  | 0, state =>
    let leaves : List Expr := [.name (octetsOf "a"), .name (octetsOf "this"), .int 7, .int (-7), .uint 7, .double false (octetsOf "1.5"), .double true (octetsOf "2.5"),
      .bool true, .null, .string (octetsOf "it's"), .bytes [0xff, 0x41], .int (-(2 ^ 63)), .list []]
    (leaves.getD (pick state leaves.length) .null, next state)
  | depth + 1, state =>
    let (first, state1) := tree depth (next state)
    let (second, state2) := tree depth state1
    let (third, state3) := tree depth state2
    let ops : List BinaryOp := [.or, .and, .less, .lessOrEqual, .greater, .greaterOrEqual, .equal, .notEqual, .in_, .add, .subtract, .multiply, .divide, .modulo]
    match pick state 9 with
    | 0 => (.binary (ops.getD (pick (next state3) ops.length) .add) first second, next (next state3))
    | 1 => (.conditional first second third, state3)
    | 2 => (.unary .not first, state1)
    | 3 => (.unary .negate first, state1)
    | 4 => (.select first (octetsOf "field"), state1)
    | 5 => (.index first second, state2)
    | 6 => (.call (octetsOf "size") (some first) [], state1)
    | 7 => (.call (octetsOf "f") none [first, second], state2)
    | _ => (.list [first, second, third], state3)

/-- `count` trees from `state`, of 1 to 3 parts one inside another. -/
def trees : Nat → Nat → List Expr
  | 0, _ => []
  | count + 1, state =>
    let (built, state') := tree (1 + pick state 3) (next state)
    built :: trees count state'

/-- The tokens of the sequences that a seed draws: `large`, and tokens that state more of the
lexis, some of them no token at all. -/
def wide : List String :=
  large ++ [".5", "1e3", "2.5", "0", "5u", "r'\\d'", "\"q\"", "'''m'''", "b\"y\"", "'a\\'b'", "9223372036854775808",
    "18446744073709551615u", "0x", "u", "#", "_x1", "exists", "--", "\\", "''", "e", "0X1", "1.", "..", "//c"]

/-- `count` sequences of 2 to 9 tokens of `wide`, from `state`, with a space or nothing between
two tokens: two tokens with nothing between them may read as one, or as no token. -/
def joined : Nat → Nat → List Octets
  | 0, _ => []
  | count + 1, state =>
    let length := 2 + pick state 8
    let (text, state) := (List.range length).foldl
      (fun (acc : String × Nat) _ =>
        let state := next acc.2
        let token := wide.getD (pick state wide.length) "a"
        let state := next state
        let gap := if acc.1.isEmpty || pick state 3 == 0 then "" else " "
        (acc.1 ++ gap ++ token, state))
      ("", next state)
    octetsOf text :: joined count (next state)

/-- `count` trees from `state`, of 1 to 4 parts one inside another. -/
def deeper : Nat → Nat → List Expr
  | 0, _ => []
  | count + 1, state =>
    let (built, state') := tree (1 + pick state 4) (next state)
    built :: deeper count state'

/-- The operands of the texts that `chains` draws: each is an expression by itself. -/
def operands : List String :=
  ["a", "this", "1", "2u", "1.5", "'s'", "true", "null", "(a)", "[1, 2]", "f(a)", "a.b", "a[0]", "-1", "!a", "-a", "--1.5",
    "-2.5.f()", "!-1", "a.g(1)", "b'x'", ".5", "-(1)", "!!a", "x.y.z", "- 5", "---a", "[a,]", "a.all(x, x)"]

/-- The operators of two operands, as an expression writes them. -/
def operators : List String := ["||", "&&", "<", "<=", ">", ">=", "==", "!=", "in", "+", "-", "*", "/", "%"]

/-- 2 to 7 operands from `state`, with an operator between two of them and no brackets, so the
levels of the operators alone group them. A space, or nothing, stands around an operator. -/
def chain (state : Nat) : String × Nat :=
  (List.range (2 + pick state 6)).foldl
    (fun (acc : String × Nat) index =>
      let state := next acc.2
      let operand := operands.getD (pick state operands.length) "a"
      if index == 0 then (operand, state)
      else
        let state := next state
        let operator := operators.getD (pick state operators.length) "+"
        let state := next state
        let gap := if operator == "in" || pick state 2 == 0 then " " else ""
        (acc.1 ++ gap ++ operator ++ gap ++ operand, state))
    ("", next state)

/-- `count` texts from `state`: a chain, or three chains as a conditional. -/
def chains : Nat → Nat → List Octets
  | 0, _ => []
  | count + 1, state =>
    let (first, state1) := chain (next state)
    if pick state 5 == 0 then
      let (second, state2) := chain state1
      let (third, state3) := chain state2
      octetsOf (first ++ " ? " ++ second ++ " : " ++ third) :: chains count (next state3)
    else octetsOf first :: chains count (next state1)

/-- Expressions that state each rule of the lexis, and each part of the grammar that the
sequences above do not reach. -/
def chosen : List Octets :=
  (["", " ", "a // a comment", "a // a comment\n+ b", "a\t+\n\x0cb\r", "_a1.b_2", "aB.c()", "a.b(c, d)[e].f",
    "0", "007", "0x0", "0xFF", "0xff", "0X1F", "0x", "0xg", "9223372036854775807", "9223372036854775808",
    "-9223372036854775808", "-9223372036854775809", "--9223372036854775808", "- 5", "-0x10", "18446744073709551615u",
    "18446744073709551616u", "0xffffffffffffffffu", "1U", "-1u", "1.0", "1.", ".5", "1.5e3", "1E-3", "1e+3", "1e", "1e+",
    "1.5.5", "1.5u", "1.e5", "5e-324", "1e-999", "1.7976931348623157e308", "1.7976931348623158e308",
    "1.7976931348623159e308", "1e308", "1e309", "0.0000000000000000000000000000000000001e350",
    "179769313486231570000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000.0",
    "-1.5", "--1.5", "---1.5", "-1.5.f()", "--1.5.f()", "-5.f()", "--5.f()", "- 1.5", "-(1.5)", "a - -1.5", "!-5", "!!-1.5", "!-a", "-!a", "!-5u", "!!a", "---a", "a - -1", "a--1", "a-1", "a - - 1",
    "''", "\"\"", "'a'", "\"a\"", "'a\"b'", "\"a'b\"", "'it\\'s'", "'open", "\"open", "'a\nb'", "'a\rb'",
    "''''''", "'''a'''", "'''a\nb'''", "'''a''b'''", "'''a'''b'''", "\"\"\"a\"b\"\"\"", "'''open''", "''''",
    "'\\a\\b\\f\\n\\r\\t\\v\\\\\\?\\\"\\'\\`'", "'\\x41\\X41'", "'\\xe9'", "'\\351'", "'\\377'", "'\\400'", "'\\08'",
    "'\\u00e9'", "'\\u20AC'", "'\\U0001f600'", "'\\ud800'", "'\\U00110000'", "'\\q'", "'\\x4'", "'\\u12'", "'\\'",
    "b'a'", "B'a'", "b\"a\"", "b'\\xff\\000\\377'", "b'\\u0041'", "b'\\U00000041'", "b'''a\nb'''",
    "r'\\d+'", "R'\\d'", "r'a\\'", "r'a\\'b'", "r\"\\\"\"", "br'\\x41'", "bR'\\n'", "Br'x'", "BR\"x\"", "rb'x'", "Rb'x'", "rr'x'", "bb'x'",
    "r'''\\'''", "b", "r", "br", "rb", "b.r", "r(b)",
    "true", "false", "null", "in", "true.a", "a.true", "a.false", "a.null", "a.in", "a.in(b)", "a in b", "a in in",
    "as", "break", "const", "continue", "else", "for", "function", "if", "import", "let", "loop", "package", "namespace",
    "return", "var", "void", "while", "a.as", "a.package()", "package()", "as(a)", "format", "truth", "inn",
    "[]", "[a]", "[a,]", "[a, b,]", "[,]", "[a,,]", "[a b]", "f()", "f(a,)", "f(,)", "a.f(b,)", "a[]", "a[b,]", "a[b][c]",
    "(a)", "((a))", "()", "(a", "a)", "a ? b : c", "a ? b : c ? d : e", "a ? b ? c : d : e", "a ? b", "a ? : c", "a : b",
    "a || b && c || d", "a < b + c * d && e in f", "a - b - c", "a / b % c * d", "a == b != c", "a < b < c",
    "a = b", "a & b", "a | b", "a <> b", "a === b", "a !== b", "a !b", "a ! = b", "#", "a @ b", "a ; b", "{}", "{a: b}", "a{b: c}", ".a", "a..b", "a.", "a.1", "a.(b)",
    "1.size()", "1.5.floor()", "-5.abs()", "(-5).abs()", "-a.b", "[1][0]", "'s'.size()", "!a.b[c]"].map octetsOf) ++
  -- Octets that are no ASCII: in a string, in a bytes literal, in a comment, and outside each.
  [octetsOf "'" ++ [0xc3, 0xa9] ++ octetsOf "'", octetsOf "b'" ++ [0xff] ++ octetsOf "'", octetsOf "'" ++ [0x00, 0x01] ++ octetsOf "'",
    octetsOf "a //" ++ [0xff], octetsOf "a + " ++ [0xc3, 0xa9], [0xc3, 0xa9]]

/-- Every expression of the file, in its order. -/
def expressions : List Octets :=
  chosen ++
    ([1, 2, 3].flatMap fun n => (sequences small n).map spaced) ++
    (sequences small 2).map (fun tokens => octetsOf (String.join tokens)) ++
    longer 1200 20261121 ++
    (trees 600 34).map write

/-- The lines of the vector file. -/
def lines : List String :=
  "# expression, a tab, and the text of its tree or \"!\" for a text that is no expression. An octet that is not printable \
    ASCII, and \"%\", is \"%\" and two hexadecimal digits. From spec/lean/ConnectZig/Cel, by spec/lean/Vectors.lean; do not edit." ::
    expressions.map line

/-- The trees whose text the model does not read back as the tree: none, or the model is
wrong. -/
def unread : List Expr := (trees 600 34).filter fun built => parse (write built) != some built

def usage : String := "usage: vectors (--write | --check) <src/protovalidate/cel directory> | vectors --random <seed> <count>"

/-- Prints the vectors of the expressions that a seed draws; 1 when the model does not read a
drawn tree's text back as the tree. -/
def random (seed count : Nat) : IO UInt32 := do
  let state := next (seed + 1)
  let drawn := deeper count (next (next state))
  if let built :: _ := drawn.filter fun built => parse (write built) != some built then
    IO.eprintln s!"the model does not read its own text back: {fileText (write built)}"
    return 1
  IO.println s!"# vectors of the CEL model from the seed {seed}: expression, a tab, and the text of its tree or \"!\"."
  let texts := joined count state ++ longer count (next state) ++ chains count (next (next (next state))) ++ drawn.map write
  for expression in texts do
    IO.println (line expression)
  return 0

/-- Writes the file, or checks it against what the model gives; 1 when it differs. With
`--random`, prints the vectors a seed draws. -/
def main (arguments : List String) : IO UInt32 := do
  if let ["--random", seed, count] := arguments then
    let (some seed, some count) := (seed.toNat?, count.toNat?) | IO.eprintln usage; return 2
    return ← random seed count
  let [mode, directory] := arguments | IO.eprintln usage; return 2
  unless mode == "--write" || mode == "--check" do
    IO.eprintln usage
    return 2
  if let built :: _ := unread then
    IO.eprintln s!"the model does not read its own text back: {fileText (write built)}"
    return 1
  let path := System.FilePath.mk directory / "cel_vectors.txt"
  let text := "\n".intercalate lines ++ "\n"
  if mode == "--write" then
    IO.FS.writeFile path text
    return 0
  if (← IO.FS.readFile path) != text then
    IO.eprintln s!"{path}: not what the model gives; run `zig build lean -- write`"
    return 1
  return 0
