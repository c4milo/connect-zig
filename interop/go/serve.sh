#!/bin/sh
# Serves a Go interop server for connect-zig's interop client (interop/README.md, "The server
# side"): connect-go in Connect, gRPC and gRPC-Web as `go`, or grpc-go in gRPC as `grpc-go`. It
# generates the schema's Go code as run.sh does, builds the server into the same cache, and runs
# it. The descriptors go unused.
#
#   interop/go/serve.sh <go|grpc-go> <port> <chain> <key> <descriptors>
set -eu
case "${1:-}" in
    go) library=connect ;;
    grpc-go) library=grpc ;;
    *)
        echo "usage: $0 <go|grpc-go> <port> <chain> <key> <descriptors>" >&2
        exit 2
        ;;
esac
cd "$(dirname "$0")"
buf="${BUF:-buf}"
export GOFLAGS=-mod=readonly
bin="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/interop-go-$(sha256sum go.sum | cut -c1-12)"
if [ ! -x "${bin}/protoc-gen-go-grpc" ]; then
    mkdir -p "${bin}"
    go build -o "${bin}/protoc-gen-go" google.golang.org/protobuf/cmd/protoc-gen-go
    go build -o "${bin}/protoc-gen-connect-go" connectrpc.com/connect/cmd/protoc-gen-connect-go
    go build -o "${bin}/protoc-gen-go-grpc" google.golang.org/grpc/cmd/protoc-gen-go-grpc
fi
PATH="${bin}:${PATH}" "${buf}" generate
go build -o "${bin}/interop-server" ./server
exec "${bin}/interop-server" "${library}" "$2" "$3" "$4"
