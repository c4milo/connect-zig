#!/usr/bin/env python3
"""Refuses control flow at a Python module's top level (tools/complexity_check.sh).

    tools/complexity/top_level.py <file>...

complexipy scores the cognitive complexity of each function, and no code at a module's top level.
So a script that does its work outside functions escapes the limit. This script prints each
statement at a module's top level, or in a class body, that branches or loops: if, for, while,
try, with, match, a conditional expression, a comprehension, or `and` and `or`. It allows
imports, definitions, plain assignments, and one guard `if __name__ == "__main__":`, whose body
it reads by the same rule. It exits 1 when it prints a finding.
"""

import ast
import sys

# The statements that branch or loop.
BRANCHING_STATEMENTS = (
    ast.If,
    ast.For,
    ast.AsyncFor,
    ast.While,
    ast.Try,
    ast.TryStar,
    ast.With,
    ast.AsyncWith,
    ast.Match,
)
# The expressions that branch or loop.
BRANCHING_EXPRESSIONS = (ast.IfExp, ast.BoolOp, ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
# The statements that hold no code of their own at the top level.
DEFINITIONS = (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.AsyncFunctionDef)


def is_main_guard(statement):
    """Whether the statement is `if __name__ == "__main__":` with no else."""
    if not isinstance(statement, ast.If) or statement.orelse:
        return False
    test = statement.test
    return (
        isinstance(test, ast.Compare)
        and isinstance(test.left, ast.Name)
        and test.left.id == "__name__"
        and len(test.ops) == 1
        and isinstance(test.ops[0], ast.Eq)
        and isinstance(test.comparators[0], ast.Constant)
        and test.comparators[0].value == "__main__"
    )


def block_findings(statements):
    """Yields the line and the kind of each statement of the block that branches or loops."""
    for statement in statements:
        yield from statement_findings(statement)


def statement_findings(statement):
    """Yields the line and the kind of the statement's first branch, if it has one."""
    if isinstance(statement, DEFINITIONS):
        return
    if isinstance(statement, ast.ClassDef) or is_main_guard(statement):
        yield from block_findings(statement.body)
        return
    if isinstance(statement, BRANCHING_STATEMENTS):
        yield statement.lineno, type(statement).__name__
        return
    branch = next((node for node in ast.walk(statement) if isinstance(node, BRANCHING_EXPRESSIONS)), None)
    if branch is not None:
        yield branch.lineno, type(branch).__name__


def file_findings(path):
    """The finding lines of one file."""
    with open(path, encoding="utf-8") as file:
        tree = ast.parse(file.read(), filename=path)
    return [
        f"{path}:{line}: {kind} at the top level, where no function's score counts it"
        for line, kind in block_findings(tree.body)
    ]


def main(paths):
    """Prints the findings of each file, and gives 1 when there is one."""
    lines = [line for path in paths for line in file_findings(path)]
    for line in lines:
        print(line)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
