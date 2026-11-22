#!/bin/sh
# Checks the specifications of docs/specs and the code's citations of them (docs/specs/README.md).
#
# - Each file of docs/specs has the checksum that docs/specs/SHA256SUMS holds, so a copy stays as
#   its publisher wrote it.
# - Each citation `CEL language definition, "<section>"` in src/protovalidate, in spec/ and in
#   tools/cel_differential names a heading of docs/specs/cel/langdef.md. A citation that names
#   several sections names each in quotes: "Macros", "List Operators" and "Map Operators".
# - Each citation `CEL strings extension, "<section>"` names a heading of
#   docs/specs/cel/strings.md, the same way.
#
# It needs python3.
set -eu
cd "$(dirname "$0")/.."
if command -v sha256sum >/dev/null 2>&1; then
    (cd docs/specs && sha256sum -c SHA256SUMS)
else
    (cd docs/specs && shasum -a 256 -c SHA256SUMS)
fi
python3 - <<'PYTHON'
import glob
import pathlib
import re
import sys

def headings_of(path):
    return set(re.findall(r"^#+ (.+)$", pathlib.Path(path).read_text(encoding="utf-8"), re.M))


documents = {
    "CEL language definition": headings_of("docs/specs/cel/langdef.md"),
    "CEL strings extension": headings_of("docs/specs/cel/strings.md"),
}
paths = glob.glob("src/protovalidate/**/*.zig", recursive=True) + glob.glob("spec/**/*.lean", recursive=True)
paths += glob.glob("tools/cel_differential/*.zig") + ["spec/README.md"]
count = 0
wrong = []
for path in sorted(paths):
    text = pathlib.Path(path).read_text(encoding="utf-8")
    # A citation may go on to the comment's next line.
    joined = re.sub(r"\n\s*(//[/!]?|--)\s*", " ", text)
    for document, headings in documents.items():
        for cited in re.finditer(document + r',\s*((?:"[^"]+"(?:\s*(?:and|,)\s*)*)+)', joined):
            for name in re.findall(r'"([^"]+)"', cited.group(1)):
                count += 1
                if name not in headings:
                    wrong.append(f"{path}: the {document} has no section \"{name}\"")
print("\n".join(wrong) if wrong else f"{count} citations of the CEL specifications name a section of them")
sys.exit(1 if wrong else 0)
PYTHON
