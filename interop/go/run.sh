#!/bin/sh
# Runs the Go interop client: generates the schema's Go code with the plugins go.mod pins, then
# runs connect-go and grpc-go against the server (interop/README.md).
#
#   interop/go/run.sh <base-url> <cases-dir> <descriptors>
set -eu
cd "$(dirname "$0")"
buf="${BUF:-buf}"
export GOFLAGS=-mod=readonly
# The plugins and the client, built once into a cache keyed by go.sum.
bin="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/interop-go-$(sha256sum go.sum | cut -c1-12)"
if [ ! -x "${bin}/protoc-gen-go-grpc" ]; then
    mkdir -p "${bin}"
    go build -o "${bin}/protoc-gen-go" google.golang.org/protobuf/cmd/protoc-gen-go
    go build -o "${bin}/protoc-gen-connect-go" connectrpc.com/connect/cmd/protoc-gen-connect-go
    go build -o "${bin}/protoc-gen-go-grpc" google.golang.org/grpc/cmd/protoc-gen-go-grpc
fi
PATH="${bin}:${PATH}" "${buf}" generate
go build -o "${bin}/interop" .
"${bin}/interop" "$1" "$2"
