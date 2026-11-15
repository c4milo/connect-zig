#!/bin/sh
# Builds and runs examples/quickstart, the README's "Use it in your project" as a project, against
# connect-zig as a fetched package (decision 41). `zig fetch` keeps only the files that `.paths`
# of `build.zig.zon` names. So a file that the build needs and the list omits fails here, and
# nowhere else: each other check builds the whole tree.
# The copy of the project names the fetched package in place of its path. It installs the plugin
# from it, runs `buf generate`, and fails when the code differs from the committed gen/. Then
# `zig build test` runs the quickstart's check.sh: the server presents the examples' test identity
# (decision 25), and the client and curl call it over h11, h2 and h3. `oidc` in the server also
# proves that connect-zig's request for chapulin equals colibri's (decision 34). It needs the
# network, for the packages connect-zig depends on, buf (or `BUF` naming it) and curl.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
identity="$(pwd)/examples/harness/tls"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
# The tracked files, as the working tree holds them.
git ls-files -z | tar --null -T - -czf "${scratch}/connect-zig.tar.gz"
cp -R examples/quickstart "${scratch}/project"
rm -rf "${scratch}/project/zig-out" "${scratch}/project/.zig-cache" "${scratch}/project/zig-pkg"
cd "${scratch}/project"
# The copy names connect-zig by path. `zig fetch --save` over a path writes the URL into the path,
# so the copy drops the entry, and the fetch adds it again with the URL and the hash.
sed -i.bak '/connect-zig by URL/d; /\.connect_zig = \.{ \.path = "\.\.\/\.\." },/d' build.zig.zon
rm -f build.zig.zon.bak
! grep -q '\.path = "\.\./\.\."' build.zig.zon
zig fetch --save=connect_zig "file://${scratch}/connect-zig.tar.gz"
grep -q 'connect-zig.tar.gz' build.zig.zon
zig build plugin
test -x zig-out/bin/protoc-gen-connect-zig
"${buf}" generate --output "${scratch}/generated"
diff -r gen "${scratch}/generated/gen"
zig build test "-Didentity=${identity}"
echo "connect-zig builds as a fetched package, and the quickstart's server and client answer each other"
