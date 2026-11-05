module github.com/c4milo/connect-zig/interop/go

go 1.24

require (
	connectrpc.com/connect v1.18.1
	golang.org/x/net v0.35.0
	google.golang.org/grpc v1.72.0
	google.golang.org/protobuf v1.36.12
)

require (
	golang.org/x/sys v0.30.0 // indirect
	golang.org/x/text v0.22.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20250218202821-56aae31c358a // indirect
	google.golang.org/grpc/cmd/protoc-gen-go-grpc v1.5.1 // indirect
)

tool (
	connectrpc.com/connect/cmd/protoc-gen-connect-go
	google.golang.org/grpc/cmd/protoc-gen-go-grpc
	google.golang.org/protobuf/cmd/protoc-gen-go
)
