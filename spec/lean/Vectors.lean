import Cel

/-!
# Vectors of the CEL model

Writes, or checks, `cel_vectors.txt` beside the Zig grammar: expressions, each with the text of
the tree the model reads of it, or "!" for a text that is no expression. A Zig unit test
requires the Zig grammar to read each expression as the model does (spec/lean/README.md).

    lake exe vectors (--write | --check) <src/protovalidate/cel directory>

The expressions are every sequence of up to three tokens of a small alphabet, each pair of
those tokens with no space between them, sequences of more tokens that a fixed generator
picks, trees that the same generator builds, and literals that state each rule of the lexis.
Before it writes or checks, the program requires the model to read each tree's text back as
the tree.
-/
open Cel

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
    let leaves : List Expr := [.name (octetsOf "a"), .name (octetsOf "this"), .int 7, .int (-7), .uint 7, .double (octetsOf "1.5"),
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
    "-1.5", "--1.5", "!-5", "!!-1.5", "!-a", "-!a", "!-5u", "!!a", "---a", "a - -1", "a--1", "a-1", "a - - 1",
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
    ASCII, and \"%\", is \"%\" and two hexadecimal digits. From spec/lean/Cel, by spec/lean/Vectors.lean; do not edit." ::
    expressions.map line

/-- The trees whose text the model does not read back as the tree: none, or the model is
wrong. -/
def unread : List Expr := (trees 600 34).filter fun built => parse (write built) != some built

/-- Writes the file, or checks it against what the model gives; 1 when it differs. -/
def main (arguments : List String) : IO UInt32 := do
  let usage := "usage: vectors (--write | --check) <src/protovalidate/cel directory>"
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
