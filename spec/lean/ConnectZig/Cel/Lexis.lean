/-!
# The lexis of CEL

The tokens of a CEL expression, written from the CEL language definition, "Syntax": the
productions `IDENT`, `INT_LIT`, `UINT_LIT`, `FLOAT_LIT`, `STRING_LIT`, `BYTES_LIT`, `ESCAPE`,
`WHITESPACE` and `COMMENT`. An expression is a list of octets, as the Zig reader takes it.

`lex` gives the tokens of an expression, or `none` for an expression that holds an octet or a
literal that the lexis does not state.
-/
namespace ConnectZig.Cel

/-- An expression's text, and the octets of a string. -/
abbrev Octets := List UInt8

/-- The octets of a Lean string, as UTF-8. -/
def octetsOf (s : String) : Octets := s.toUTF8.toList

/-- One token. A literal holds its value, so the grammar reads no text. -/
inductive Token where
  /-- `[_a-zA-Z][_a-zA-Z0-9]*`: a name, a keyword or a reserved word. -/
  | word (name : Octets)
  /-- `INT_LIT` without its sign, which the grammar reads. -/
  | int (magnitude : Nat)
  /-- `UINT_LIT`. -/
  | uint (magnitude : Nat)
  /-- `FLOAT_LIT` without its sign, as its text. -/
  | double (text : Octets)
  /-- `STRING_LIT`, as the octets it states. -/
  | string (octets : Octets)
  /-- `BYTES_LIT`, as the octets it states. -/
  | bytes (octets : Octets)
  /-- An operator or a bracket. -/
  | mark (text : String)
  deriving BEq, Repr

/-- `DIGIT ::= [0-9]`. -/
def isDigit (b : UInt8) : Bool := 0x30 ≤ b && b ≤ 0x39

/-- `HEXDIGIT ::= [0-9abcdefABCDEF]`. -/
def isHex (b : UInt8) : Bool := isDigit b || (0x61 ≤ b && b ≤ 0x66) || (0x41 ≤ b && b ≤ 0x46)

/-- `[_a-zA-Z]`. -/
def isWordStart (b : UInt8) : Bool := b == 0x5f || (0x61 ≤ b && b ≤ 0x7a) || (0x41 ≤ b && b ≤ 0x5a)

/-- `[_a-zA-Z0-9]`. -/
def isWord (b : UInt8) : Bool := isWordStart b || isDigit b

/-- `WHITESPACE ::= [\t\n\f\r ]+`. -/
def isSpace (b : UInt8) : Bool := b == 0x09 || b == 0x0a || b == 0x0c || b == 0x0d || b == 0x20

/-- The value of a hexadecimal digit. -/
def hexValue (b : UInt8) : Nat :=
  if isDigit b then b.toNat - 0x30
  else if 0x61 ≤ b && b ≤ 0x66 then b.toNat - 0x61 + 10
  else b.toNat - 0x41 + 10

/-- The number that digits state in `base`, the first digit the most significant. -/
def numberOf (base : Nat) (digits : Octets) : Nat :=
  digits.foldl (fun n b => n * base + hexValue b) 0

/-- The UTF-8 octets of a code point. A code point that is no Unicode scalar value, a
surrogate or one past U+10FFFF, is written as U+FFFD. -/
def utf8 (c : Nat) : Octets :=
  let c := if (0xd800 ≤ c && c ≤ 0xdfff) || c > 0x10ffff then 0xfffd else c
  let tail (n : Nat) : UInt8 := UInt8.ofNat (0x80 + n % 64)
  if c < 0x80 then [UInt8.ofNat c]
  else if c < 0x800 then [UInt8.ofNat (0xc0 + c / 64), tail c]
  else if c < 0x10000 then [UInt8.ofNat (0xe0 + c / 4096), tail (c / 64), tail c]
  else [UInt8.ofNat (0xf0 + c / 262144), tail (c / 4096), tail (c / 64), tail c]

/-- The octets one `ESCAPE` states after its backslash, and the text after it. In a string an
escape of a number states a code point, and in a bytes literal an octet. `\u` and `\U` state a
code point, which a bytes literal does not hold. -/
def escape (ofBytes : Bool) : Octets → Option (Octets × Octets)
  | 0x61 :: r => some ([0x07], r)  -- \a
  | 0x62 :: r => some ([0x08], r)  -- \b
  | 0x66 :: r => some ([0x0c], r)  -- \f
  | 0x6e :: r => some ([0x0a], r)  -- \n
  | 0x72 :: r => some ([0x0d], r)  -- \r
  | 0x74 :: r => some ([0x09], r)  -- \t
  | 0x76 :: r => some ([0x0b], r)  -- \v
  | 0x5c :: r => some ([0x5c], r)
  | 0x3f :: r => some ([0x3f], r)
  | 0x22 :: r => some ([0x22], r)
  | 0x27 :: r => some ([0x27], r)
  | 0x60 :: r => some ([0x60], r)
  | x :: a :: b :: r =>
    let numbered (n : Nat) : Octets := if ofBytes then [UInt8.ofNat n] else utf8 n
    if (x == 0x78 || x == 0x58) && isHex a && isHex b then some (numbered (numberOf 16 [a, b]), r)
    else if x == 0x75 then
      match b :: r with
      | b :: c :: d :: r' =>
        if !ofBytes && isHex a && isHex b && isHex c && isHex d then some (utf8 (numberOf 16 [a, b, c, d]), r')
        else none
      | _ => none
    else if x == 0x55 then
      let digits := (a :: b :: r).take 8
      if !ofBytes && digits.length == 8 && digits.all isHex then
        some (utf8 (numberOf 16 digits), (a :: b :: r).drop 8)
      else none
    else if 0x30 ≤ x && x ≤ 0x33 && 0x30 ≤ a && a ≤ 0x37 && 0x30 ≤ b && b ≤ 0x37 then
      some (numbered (numberOf 8 [x, a, b]), r)
    else none
  | _ => none

/-- Whether `text` starts with `quote` three times. -/
def startsTriple (quote : UInt8) : Octets → Bool
  | a :: b :: c :: _ => a == quote && b == quote && c == quote
  | _ => false

/-- The body of a string literal after its opening quotes: the octets it states and the text
after its closing quotes. A string in single quotes holds no line end, and a string in three
quotes holds any octet. A raw string keeps its backslashes, and ends at its first closing
quotes, a backslash before them or not. -/
def stringBody (ofBytes raw triple : Bool) (quote : UInt8) : Nat → Octets → Octets → Option (Octets × Octets)
  | 0, _, _ => none
  | _, _, [] => none
  | fuel + 1, done, b :: rest =>
    if b == quote && (!triple || startsTriple quote (b :: rest)) then
      some (done.reverse, if triple then rest.drop 2 else rest)
    else if !triple && (b == 0x0a || b == 0x0d) then none
    else if b == 0x5c && !raw then
      -- An escape, or a backslash before what starts none, which no string holds.
      match escape ofBytes rest with
      | some (octets, rest') => stringBody ofBytes raw triple quote fuel (octets.reverse ++ done) rest'
      | none => none
    -- In a raw string a backslash is an octet as any other: it keeps no quote from closing.
    else stringBody ofBytes raw triple quote fuel (b :: done) rest

/-- `STRING_LIT` and `BYTES_LIT` at the start of `text`, after a prefix that was read:
"BYTES_LIT ::= [bB] STRING_LIT" and "STRING_LIT ::= [rR]? ...". -/
def stringLiteral (ofBytes raw : Bool) (text : Octets) : Option (Token × Octets) :=
  match text with
  | quote :: rest =>
    if quote != 0x22 && quote != 0x27 then none
    else
      let triple := startsTriple quote text
      let body := if triple then rest.drop 2 else rest
      match stringBody ofBytes raw triple quote (text.length + 1) [] body with
      | some (octets, rest') => some (if ofBytes then .bytes octets else .string octets, rest')
      | none => none
  | [] => none

/-- The prefix of a string literal at the start of `text`: whether it is a bytes literal,
whether it is raw, and the text from its quote. `none` when `text` starts no string. -/
def stringPrefix (text : Octets) : Option (Bool × Bool × Octets) :=
  let isQuote (b : UInt8) : Bool := b == 0x22 || b == 0x27
  let isB (b : UInt8) : Bool := b == 0x62 || b == 0x42
  let isR (b : UInt8) : Bool := b == 0x72 || b == 0x52
  match text with
  | q :: _ => if isQuote q then some (false, false, text) else
    match text with
    | p :: q :: rest =>
      if isR p && isQuote q then some (false, true, q :: rest)
      else if isB p && isQuote q then some (true, false, q :: rest)
      else match rest with
        | q2 :: rest2 => if isB p && isR q && isQuote q2 then some (true, true, q2 :: rest2) else none
        | [] => none
    | _ => none
  | [] => none

/-- `EXPONENT ::= [eE] [+-]? DIGIT+` at the start of `text`: its octets, or none. -/
def exponent (text : Octets) : Octets :=
  match text with
  | e :: rest =>
    if e != 0x65 && e != 0x45 then [] else
      let (sign, rest) := match rest with
        | s :: rest' => if s == 0x2b || s == 0x2d then ([s], rest') else ([], rest)
        | [] => ([], rest)
      let digits := rest.takeWhile isDigit
      if digits.isEmpty then [] else e :: sign ++ digits
  | [] => []

/-- A number at the start of `text`, which starts with a digit, or with "." and a digit:
`INT_LIT`, `UINT_LIT` or `FLOAT_LIT`, without a sign. -/
def number (text : Octets) : Token × Octets :=
  let hexDigits := (text.drop 2).takeWhile isHex
  if text.take 2 == [0x30, 0x78] && !hexDigits.isEmpty then
    -- "INT_LIT ::= ... | -? 0x HEXDIGIT+".
    let rest := text.drop (2 + hexDigits.length)
    match rest with
    | u :: rest' => if u == 0x75 || u == 0x55 then (.uint (numberOf 16 hexDigits), rest') else (.int (numberOf 16 hexDigits), rest)
    | [] => (.int (numberOf 16 hexDigits), rest)
  else
    let whole := text.takeWhile isDigit
    let rest := text.drop whole.length
    let fraction := match rest with
      | dot :: rest' => if dot == 0x2e && !(rest'.takeWhile isDigit).isEmpty then dot :: rest'.takeWhile isDigit else []
      | [] => []
    let rest := rest.drop fraction.length
    let exp := exponent rest
    if fraction.isEmpty && exp.isEmpty then
      match rest with
      | u :: rest' => if u == 0x75 || u == 0x55 then (.uint (numberOf 10 whole), rest') else (.int (numberOf 10 whole), rest)
      | [] => (.int (numberOf 10 whole), rest)
    else (.double (whole ++ fraction ++ exp), rest.drop exp.length)

/-- The operator or the bracket at the start of `text`, the longest one. -/
def mark (text : Octets) : Option (String × Octets) :=
  let pairs := ["&&", "||", "<=", ">=", "==", "!="]
  let singles := ["(", ")", "[", "]", "{", "}", ".", ",", "?", ":", "+", "-", "*", "/", "%", "!", "<", ">"]
  match (pairs ++ singles).find? (fun m => (octetsOf m).isPrefixOf text) with
  | some m => some (m, text.drop (octetsOf m).length)
  | none => none

/-- The tokens of `text`, or `none` when it holds what the lexis does not state. -/
def lexFrom : Nat → Octets → Option (List Token)
  | 0, _ => none
  | _, [] => some []
  | fuel + 1, b :: rest =>
    let text := b :: rest
    if isSpace b then lexFrom fuel rest
    else if text.take 2 == [0x2f, 0x2f] then
      -- "COMMENT ::= '//' ~\n* \n".
      lexFrom fuel (text.dropWhile (· != 0x0a))
    else match stringPrefix text with
      | some (ofBytes, raw, quoted) =>
        match stringLiteral ofBytes raw quoted with
        | some (token, rest') => (lexFrom fuel rest').map (token :: ·)
        | none => none
      | none =>
        if isWordStart b then
          let name := text.takeWhile isWord
          (lexFrom fuel (text.drop name.length)).map (.word name :: ·)
        else if isDigit b || (b == 0x2e && (rest.head?.map isDigit).getD false) then
          let (token, rest') := number text
          (lexFrom fuel rest').map (token :: ·)
        else match mark text with
          | some (m, rest') => (lexFrom fuel rest').map (.mark m :: ·)
          | none => none

/-- The tokens of an expression. -/
def lex (text : Octets) : Option (List Token) := lexFrom (text.length + 1) text

end ConnectZig.Cel
