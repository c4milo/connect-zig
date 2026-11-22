import ConnectZig.Cel.Grammar

/-!
# The text of a tree

A tree as an expression with each part in brackets, which reads back as the same tree. The Zig
grammar writes the tree it reads of an expression in this form (`cel_tree.write`, with each
double as its text), and a test requires the two texts to be equal.
-/
namespace ConnectZig.Cel

/-- An operator of two operands as an expression writes it. -/
def BinaryOp.text : BinaryOp → String
  | .or => "||" | .and => "&&" | .less => "<" | .lessOrEqual => "<=" | .greater => ">"
  | .greaterOrEqual => ">=" | .equal => "==" | .notEqual => "!=" | .in_ => "in" | .add => "+"
  | .subtract => "-" | .multiply => "*" | .divide => "/" | .modulo => "%"

/-- The digits of a number below 16 in hexadecimal, in lower case. -/
def hexDigit (n : Nat) : UInt8 := UInt8.ofNat (if n < 10 then 0x30 + n else 0x61 + n - 10)

/-- One octet of a string or of a bytes literal. A string keeps each octet but a backslash, a
single quote and the line ends. A bytes literal keeps printable ASCII and writes each other
octet as "\x" and two digits. -/
def writtenOctet (ofBytes : Bool) (b : UInt8) : Octets :=
  if b == 0x5c || b == 0x27 then [0x5c, b]
  else if b == 0x0a then [0x5c, 0x6e]
  else if b == 0x0d then [0x5c, 0x72]
  else if b == 0x09 then [0x5c, 0x74]
  else if !ofBytes || (0x20 ≤ b && b ≤ 0x7e) then [b]
  else [0x5c, 0x78, hexDigit (b.toNat / 16), hexDigit (b.toNat % 16)]

/-- Whether a tree's text starts with a number. A "-" before such a text is the number's sign,
so a negation of the tree is written with the tree in brackets. -/
def startsWithNumber : Expr → Bool
  | .int _ => true
  | .double _ _ => true
  | .select of _ => startsWithNumber of
  | .index of _ => startsWithNumber of
  | .call _ (some target) _ => startsWithNumber target
  | _ => false

mutual

/-- The text of a tree. -/
def write : Expr → Octets
  | .int value => octetsOf (toString value)
  | .uint value => octetsOf (toString value) ++ octetsOf "u"
  | .double negative text => (if negative then octetsOf "-" else []) ++ text
  | .bool value => octetsOf (if value then "true" else "false")
  | .string octets => octetsOf "'" ++ octets.flatMap (writtenOctet false) ++ octetsOf "'"
  | .bytes octets => octetsOf "b'" ++ octets.flatMap (writtenOctet true) ++ octetsOf "'"
  | .null => octetsOf "null"
  | .name text => text
  | .select of field => write of ++ octetsOf "." ++ field
  | .index of at_ => write of ++ octetsOf "[" ++ write at_ ++ octetsOf "]"
  | .unary .not of => octetsOf "(!" ++ write of ++ octetsOf ")"
  -- A "-" before a number is the number's sign, so a text that starts with a number is
  -- written in brackets when a "-" negates it.
  | .unary .negate of =>
    if startsWithNumber of then octetsOf "(-(" ++ write of ++ octetsOf "))" else octetsOf "(-" ++ write of ++ octetsOf ")"
  | .binary op left right => octetsOf "(" ++ write left ++ octetsOf (" " ++ op.text ++ " ") ++ write right ++ octetsOf ")"
  | .conditional condition thenValue otherwise =>
    octetsOf "(" ++ write condition ++ octetsOf " ? " ++ write thenValue ++ octetsOf " : " ++ write otherwise ++ octetsOf ")"
  | .call name none arguments => name ++ octetsOf "(" ++ writeList arguments ++ octetsOf ")"
  | .call name (some target) arguments => write target ++ octetsOf "." ++ name ++ octetsOf "(" ++ writeList arguments ++ octetsOf ")"
  | .list elements => octetsOf "[" ++ writeList elements ++ octetsOf "]"
  | .map entries => octetsOf "{" ++ writeEntries entries ++ octetsOf "}"

/-- The texts of the parts of a list, with ", " between them. -/
def writeList : List Expr → Octets
  | [] => []
  | [e] => write e
  | e :: rest => write e ++ octetsOf ", " ++ writeList rest

/-- The texts of a map literal's entries, each key with ": " and its value, and ", " between
two entries. -/
def writeEntries : List (Expr × Expr) → Octets
  | [] => []
  | [(key, value)] => write key ++ octetsOf ": " ++ write value
  | (key, value) :: rest => write key ++ octetsOf ": " ++ write value ++ octetsOf ", " ++ writeEntries rest

end

end ConnectZig.Cel
