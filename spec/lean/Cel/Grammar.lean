import Cel.Lexis

/-!
# The grammar of CEL

The grammar of the CEL language definition, "Syntax", one function for each production, over
the tokens of `Cel.lex`:

    Expr           = ConditionalOr ["?" ConditionalOr ":" Expr]
    ConditionalOr  = [ConditionalOr "||"] ConditionalAnd
    ConditionalAnd = [ConditionalAnd "&&"] Relation
    Relation       = [Relation Relop] Addition
    Addition       = [Addition ("+" | "-")] Multiplication
    Multiplication = [Multiplication ("*" | "/" | "%")] Unary
    Unary          = Member | "!" {"!"} Member | "-" {"-"} Member
    Member         = Primary | Member "." SELECTOR ["(" [ExprList] ")"] | Member "[" Expr "]"
    Primary        = IDENT ["(" [ExprList] ")"] | "(" Expr ")" | "[" [ExprList] [","] "]" | LITERAL

`protovalidate` reads no map literal, no message literal and no name that starts with ".", so
the model has none: an expression that holds one has no tree.

A number's sign is part of its literal ("INT_LIT ::= -? DIGIT+", "FLOAT_LIT ::= -? ..."). The
model reads the last "-" of a run before a number as that sign. An int then holds its sign,
and a double is a negation of its text, which states the same number.
-/
namespace Cel

/-- An operator of two operands. -/
inductive BinaryOp where
  /-- `||`. -/
  | or
  /-- `&&`. -/
  | and
  /-- `<`. -/
  | less
  /-- `<=`. -/
  | lessOrEqual
  /-- `>`. -/
  | greater
  /-- `>=`. -/
  | greaterOrEqual
  /-- `==`. -/
  | equal
  /-- `!=`. -/
  | notEqual
  /-- `in`. -/
  | in_
  /-- `+`. -/
  | add
  /-- `-`. -/
  | subtract
  /-- `*`. -/
  | multiply
  /-- `/`. -/
  | divide
  /-- `%`. -/
  | modulo
  deriving BEq, Repr

/-- An operator of one operand. -/
inductive UnaryOp where
  /-- `!`. -/
  | not
  /-- `-`. -/
  | negate
  deriving BEq, Repr

/-- The tree of an expression. -/
inductive Expr where
  /-- An int literal, with its sign. -/
  | int (value : Int)
  /-- A uint literal. -/
  | uint (value : Nat)
  /-- A double literal's text, without a sign. -/
  | double (text : Octets)
  /-- `true` or `false`. -/
  | bool (value : Bool)
  /-- A string literal's octets. -/
  | string (octets : Octets)
  /-- A bytes literal's octets. -/
  | bytes (octets : Octets)
  /-- `null`. -/
  | null
  /-- An identifier. -/
  | name (text : Octets)
  /-- `of.field`. -/
  | select (of : Expr) (field : Octets)
  /-- `of[at_]`. -/
  | index (of : Expr) (at_ : Expr)
  /-- An operator before its operand. -/
  | unary (op : UnaryOp) (of : Expr)
  /-- An operator between its operands. -/
  | binary (op : BinaryOp) (left right : Expr)
  /-- `condition ? thenValue : otherwise`. -/
  | conditional (condition thenValue otherwise : Expr)
  /-- `name(arguments)`, or `target.name(arguments)`. -/
  | call (name : Octets) (target : Option Expr) (arguments : List Expr)
  /-- A list literal. -/
  | list (elements : List Expr)
  deriving BEq, Repr

/-- "KEYWORD ::= BOOL_LIT | NULL_LIT | 'in'". -/
def keywords : List Octets := ["true", "false", "null", "in"].map octetsOf

/-- "RESERVED": the words that name no variable and no function but one called on a target. -/
def reserved : List Octets :=
  ["as", "break", "const", "continue", "else", "for", "function", "if", "import", "let", "loop",
    "package", "namespace", "return", "var", "void", "while"].map octetsOf

/-- The greatest double, as a ratio to 1: a decimal that is at least this number and one half
of the last place more has no double, since it rounds to an infinity. `(2^54 - 1) * 2^970` is
that bound. -/
def doubleBound : Nat := (2 ^ 54 - 1) * 2 ^ 970

/-- Whether a `FLOAT_LIT`'s text states a number that a double holds. The text is digits, a
fraction and an exponent. -/
def doubleInRange (text : Octets) : Bool :=
  let mantissa := text.takeWhile (fun b => b != 0x65 && b != 0x45)
  let exp := text.drop (mantissa.length + 1)
  let whole := mantissa.takeWhile isDigit
  let fraction := mantissa.drop (whole.length + 1)
  let digits := numberOf 10 (whole ++ fraction)
  let (negative, expDigits) := match exp with
    | s :: rest => if s == 0x2d then (true, rest) else if s == 0x2b then (false, rest) else (false, exp)
    | [] => (false, [])
  -- An exponent past 400 in size decides the question, whatever the digits are.
  let expValue := numberOf 10 (expDigits.take 5)
  let expValue := if expDigits.length > 4 then 10000 else expValue
  if digits == 0 then true
  else if negative then
    -- digits * 10^-(expValue + fraction) is below the bound unless the digits are many.
    digits < doubleBound * 10 ^ (min (expValue + fraction.length) 800)
  else if expValue > 400 + fraction.length then false
  else if expValue ≥ fraction.length then digits * 10 ^ (expValue - fraction.length) < doubleBound
  else digits < doubleBound * 10 ^ (fraction.length - expValue)

/-- The operator of a relation that `token` is. -/
def relop : Token → Option BinaryOp
  | .mark "<" => some .less
  | .mark "<=" => some .lessOrEqual
  | .mark ">" => some .greater
  | .mark ">=" => some .greaterOrEqual
  | .mark "==" => some .equal
  | .mark "!=" => some .notEqual
  | .word w => if w == octetsOf "in" then some .in_ else none
  | _ => none

/-- A result of a production: the tree it read and the tokens after it. -/
abbrev Read := Option (Expr × List Token)

/-- `count` negations of `e`, or `count` logical nots. -/
def applyUnary (op : UnaryOp) : Nat → Expr → Expr
  | 0, e => e
  | n + 1, e => .unary op (applyUnary op n e)

/-- A literal number after a "-", which is its sign. -/
def signed : List Token → Read
  | .int magnitude :: ts => if magnitude ≤ 2 ^ 63 then some (.int (-(magnitude : Int)), ts) else none
  | .double text :: ts => if doubleInRange text then some (.unary .negate (.double text), ts) else none
  | _ => none

mutual

/-- `Expr`. -/
def expr : Nat → List Token → Read
  | 0, _ => none
  | fuel + 1, ts => do
    let (condition, ts) ← conditionalOr fuel ts
    match ts with
    | .mark "?" :: ts => do
      let (thenValue, ts) ← conditionalOr fuel ts
      match ts with
      | .mark ":" :: ts => do
        let (otherwise, ts) ← expr fuel ts
        pure (.conditional condition thenValue otherwise, ts)
      | _ => none
    | _ => pure (condition, ts)

/-- `ConditionalOr`. -/
def conditionalOr : Nat → List Token → Read
  | 0, _ => none
  | fuel + 1, ts => do
    let (left, ts) ← conditionalAnd fuel ts
    orRest fuel left ts

/-- The `"||" ConditionalAnd` parts after `left`. -/
def orRest : Nat → Expr → List Token → Read
  | 0, _, _ => none
  | fuel + 1, left, ts =>
    match ts with
    | .mark "||" :: ts => do
      let (right, ts) ← conditionalAnd fuel ts
      orRest fuel (.binary .or left right) ts
    | _ => some (left, ts)

/-- `ConditionalAnd`. -/
def conditionalAnd : Nat → List Token → Read
  | 0, _ => none
  | fuel + 1, ts => do
    let (left, ts) ← relation fuel ts
    andRest fuel left ts

/-- The `"&&" Relation` parts after `left`. -/
def andRest : Nat → Expr → List Token → Read
  | 0, _, _ => none
  | fuel + 1, left, ts =>
    match ts with
    | .mark "&&" :: ts => do
      let (right, ts) ← relation fuel ts
      andRest fuel (.binary .and left right) ts
    | _ => some (left, ts)

/-- `Relation`. -/
def relation : Nat → List Token → Read
  | 0, _ => none
  | fuel + 1, ts => do
    let (left, ts) ← addition fuel ts
    relationRest fuel left ts

/-- The `Relop Addition` parts after `left`. -/
def relationRest : Nat → Expr → List Token → Read
  | 0, _, _ => none
  | fuel + 1, left, ts =>
    match ts with
    | t :: ts' =>
      match relop t with
      | some op => do
        let (right, ts) ← addition fuel ts'
        relationRest fuel (.binary op left right) ts
      | none => some (left, ts)
    | [] => some (left, ts)

/-- `Addition`. -/
def addition : Nat → List Token → Read
  | 0, _ => none
  | fuel + 1, ts => do
    let (left, ts) ← multiplication fuel ts
    additionRest fuel left ts

/-- The `("+" | "-") Multiplication` parts after `left`. -/
def additionRest : Nat → Expr → List Token → Read
  | 0, _, _ => none
  | fuel + 1, left, ts =>
    match ts with
    | .mark "+" :: ts => do
      let (right, ts) ← multiplication fuel ts
      additionRest fuel (.binary .add left right) ts
    | .mark "-" :: ts => do
      let (right, ts) ← multiplication fuel ts
      additionRest fuel (.binary .subtract left right) ts
    | _ => some (left, ts)

/-- `Multiplication`. -/
def multiplication : Nat → List Token → Read
  | 0, _ => none
  | fuel + 1, ts => do
    let (left, ts) ← unary fuel ts
    multiplicationRest fuel left ts

/-- The `("*" | "/" | "%") Unary` parts after `left`. -/
def multiplicationRest : Nat → Expr → List Token → Read
  | 0, _, _ => none
  | fuel + 1, left, ts =>
    match ts with
    | .mark "*" :: ts => do
      let (right, ts) ← unary fuel ts
      multiplicationRest fuel (.binary .multiply left right) ts
    | .mark "/" :: ts => do
      let (right, ts) ← unary fuel ts
      multiplicationRest fuel (.binary .divide left right) ts
    | .mark "%" :: ts => do
      let (right, ts) ← unary fuel ts
      multiplicationRest fuel (.binary .modulo left right) ts
    | _ => some (left, ts)

/-- `Unary`: a member, a run of "!" before a member, or a run of "-" before a member. The last
"-" of a run before an int literal is the literal's sign. -/
def unary : Nat → List Token → Read
  | 0, _ => none
  | fuel + 1, ts =>
    match ts with
    | .mark "!" :: _ => do
      let count := (ts.takeWhile (· == .mark "!")).length
      let (operand, ts) ← member fuel (ts.drop count)
      pure (applyUnary .not count operand, ts)
    | .mark "-" :: _ =>
      let count := (ts.takeWhile (· == .mark "-")).length
      let rest := ts.drop count
      match rest with
      | .int _ :: _ => do
        -- The run's last "-" is the sign of the int, which a member starts with.
        let (operand, ts) ← member fuel (.mark "-" :: rest)
        pure (applyUnary .negate (count - 1) operand, ts)
      | _ => do
        let (operand, ts) ← member fuel rest
        pure (applyUnary .negate count operand, ts)
    | _ => member fuel ts

/-- `Member`. -/
def member : Nat → List Token → Read
  | 0, _ => none
  | fuel + 1, ts => do
    let (first, ts) ← primary fuel ts
    memberRest fuel first ts

/-- The selections, the calls and the indexes after `target`. -/
def memberRest : Nat → Expr → List Token → Read
  | 0, _, _ => none
  | fuel + 1, target, ts =>
    match ts with
    | .mark "." :: .word name :: ts =>
      -- "SELECTOR ::= [_a-zA-Z][_a-zA-Z0-9]* - KEYWORD".
      if keywords.contains name then none else
      match ts with
      | .mark "(" :: ts => do
        let (arguments, ts) ← exprList fuel false ")" ts
        memberRest fuel (.call name (some target) arguments) ts
      | _ => memberRest fuel (.select target name) ts
    | .mark "." :: _ => none
    | .mark "[" :: ts => do
      let (at_, ts) ← expr fuel ts
      match ts with
      | .mark "]" :: ts => memberRest fuel (.index target at_) ts
      | _ => none
    | _ => some (target, ts)

/-- `Primary`. -/
def primary : Nat → List Token → Read
  | 0, _ => none
  | fuel + 1, ts =>
    match ts with
    | .word name :: ts =>
      if name == octetsOf "true" then some (.bool true, ts)
      else if name == octetsOf "false" then some (.bool false, ts)
      else if name == octetsOf "null" then some (.null, ts)
      -- "IDENT ::= SELECTOR - RESERVED", and "in" is a keyword.
      else if keywords.contains name || reserved.contains name then none
      else match ts with
        | .mark "(" :: ts => do
          let (arguments, ts) ← exprList fuel false ")" ts
          pure (.call name none arguments, ts)
        | _ => some (.name name, ts)
    | .mark "(" :: ts => do
      let (inner, ts) ← expr fuel ts
      match ts with
      | .mark ")" :: ts => pure (inner, ts)
      | _ => none
    | .mark "[" :: ts => do
      let (elements, ts) ← exprList fuel true "]" ts
      pure (.list elements, ts)
    | .mark "-" :: ts => signed ts
    | .int magnitude :: ts => if magnitude < 2 ^ 63 then some (.int magnitude, ts) else none
    | .uint magnitude :: ts => if magnitude < 2 ^ 64 then some (.uint magnitude, ts) else none
    | .double text :: ts => if doubleInRange text then some (.double text, ts) else none
    | .string octets :: ts => some (.string octets, ts)
    | .bytes octets :: ts => some (.bytes octets, ts)
    | _ => none

/-- `[ExprList]` and the bracket `close` after it. A list literal takes a comma after its last
element ("'[' [ExprList] [','] ']'"), and a call's arguments take none. -/
def exprList : Nat → Bool → String → List Token → Option (List Expr × List Token)
  | 0, _, _, _ => none
  | fuel + 1, lastComma, close, ts =>
    match ts with
    | .mark m :: ts' => if m == close then some ([], ts') else exprListRest fuel lastComma close [] ts
    | _ => exprListRest fuel lastComma close [] ts

/-- The expressions of a list after those in `done`, which holds them in reverse. -/
def exprListRest : Nat → Bool → String → List Expr → List Token → Option (List Expr × List Token)
  | 0, _, _, _, _ => none
  | fuel + 1, lastComma, close, done, ts => do
    let (element, ts) ← expr fuel ts
    match ts with
    | .mark "," :: .mark m :: ts' =>
      if lastComma && m == close then pure ((element :: done).reverse, ts')
      else exprListRest fuel lastComma close (element :: done) (.mark m :: ts')
    | .mark "," :: ts => exprListRest fuel lastComma close (element :: done) ts
    | .mark m :: ts => if m == close then pure ((element :: done).reverse, ts) else none
    | _ => none

end

/-- The tree of an expression's text, or `none` for a text that is no expression. The fuel
bounds the productions one inside another: each token takes fewer than 32 of them. -/
def parse (text : Octets) : Option Expr :=
  match lex text with
  | some tokens =>
    match expr (32 * (tokens.length + 2)) tokens with
    | some (tree, []) => some tree
    | _ => none
  | none => none

end Cel
