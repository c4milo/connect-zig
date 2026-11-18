module github.com/c4milo/connect-zig/tools/fullstack/connect-go

go 1.26.0

require (
	connectrpc.com/connect v1.18.1
	google.golang.org/protobuf v1.36.12
)

tool (
	connectrpc.com/connect/cmd/protoc-gen-connect-go
	google.golang.org/protobuf/cmd/protoc-gen-go
)
