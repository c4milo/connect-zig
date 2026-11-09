// The Go interop servers: connect-go serving Connect, gRPC and gRPC-Web over h2 and HTTP/1.1,
// or grpc-go serving gRPC over h2, each over TLS with the test identity. connect-zig's interop
// client calls them (interop/README.md, "The server side"). Each answers as connect-zig's own
// server of examples/services/interop.zig does.
//
//	go run ./server <connect|grpc> <port> <chain> <key>
//
// Port 0 lets the kernel choose. The server prints "listening on port <port>" once it listens.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	_ "google.golang.org/grpc/encoding/gzip" // grpc-go reads and writes gzip once it is registered.
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	coveragev1 "github.com/c4milo/connect-zig/interop/go/gen/coverage/v1"
	interopv1 "github.com/c4milo/connect-zig/interop/go/gen/interop/v1"
	"github.com/c4milo/connect-zig/interop/go/gen/interop/v1/interopv1connect"
)

const (
	// The most messages Repeat sends, as examples/services/interop.zig allows.
	repeatMax = 16
	// The prefix of the request headers Inspect reports and sends back.
	inspectedPrefix = "x-interop-"
	// statuscodes.md: the codes a failure may carry are 1 to 16.
	codeMin = 1
	codeMax = 16
)

func main() {
	if len(os.Args) != 5 {
		fmt.Fprintln(os.Stderr, "usage: server <connect|grpc> <port> <chain> <key>")
		os.Exit(2)
	}
	identity, err := tls.LoadX509KeyPair(os.Args[3], os.Args[4])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:"+os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	fmt.Printf("listening on port %d\n", listener.Addr().(*net.TCPAddr).Port)
	switch os.Args[1] {
	case "connect":
		err = serveConnect(listener, identity)
	case "grpc":
		err = serveGrpc(listener, identity)
	default:
		err = fmt.Errorf("no server named %s", os.Args[1])
	}
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

// serveConnect serves connect-go's handler over TLS, h2 and HTTP/1.1 picked by ALPN.
func serveConnect(listener net.Listener, identity tls.Certificate) error {
	mux := http.NewServeMux()
	mux.Handle(interopv1connect.NewInteropServiceHandler(connectService{}))
	server := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{identity}, NextProtos: []string{"h2", "http/1.1"}},
	}
	return server.ServeTLS(listener, "", "")
}

// serveGrpc serves grpc-go, Google's own gRPC, over TLS and h2.
func serveGrpc(listener net.Listener, identity tls.Certificate) error {
	server := grpc.NewServer(grpc.Creds(credentials.NewServerTLSFromCert(&identity)))
	interopv1.RegisterInteropServiceServer(server, grpcService{})
	return server.Serve(listener)
}

// checkCount refuses a Repeat count outside 0 to 16.
func checkCount(count int32) error {
	if count < 0 || count > repeatMax {
		return errors.New("count must be between 0 and 16")
	}
	return nil
}

// inspected keeps each "x-interop-*" header as a "name: value" line, the name in lowercase.
func inspected(names map[string][]string, timeout time.Duration, hasTimeout bool) *interopv1.InspectResponse {
	response := &interopv1.InspectResponse{}
	for name, values := range names {
		lower := strings.ToLower(name)
		if !strings.HasPrefix(lower, inspectedPrefix) {
			continue
		}
		for _, value := range values {
			response.Headers = append(response.Headers, lower+": "+value)
		}
	}
	if hasTimeout {
		response.TimeoutMs = timeout.Milliseconds()
	}
	return response
}

// remaining is the time to the context's deadline, which the server read from the timeout.
func remaining(ctx context.Context) (time.Duration, bool) {
	deadline, ok := ctx.Deadline()
	if !ok {
		return 0, false
	}
	return time.Until(deadline), true
}

type connectService struct{}

func (connectService) Echo(_ context.Context, request *connect.Request[coveragev1.Everything]) (*connect.Response[coveragev1.Everything], error) {
	return connect.NewResponse(request.Msg), nil
}

func (connectService) EchoGet(_ context.Context, request *connect.Request[coveragev1.Everything]) (*connect.Response[coveragev1.Everything], error) {
	return connect.NewResponse(request.Msg), nil
}

func (connectService) Repeat(_ context.Context, request *connect.Request[interopv1.RepeatRequest], stream *connect.ServerStream[coveragev1.Everything]) error {
	if err := checkCount(request.Msg.Count); err != nil {
		return connect.NewError(connect.CodeOutOfRange, err)
	}
	message := request.Msg.Message
	if message == nil {
		message = &coveragev1.Everything{}
	}
	for range request.Msg.Count {
		if err := stream.Send(message); err != nil {
			return err
		}
	}
	return nil
}

func (connectService) Collect(_ context.Context, stream *connect.ClientStream[coveragev1.Everything]) (*connect.Response[interopv1.CollectResponse], error) {
	response := &interopv1.CollectResponse{}
	for stream.Receive() {
		response.Count++
		response.Last = stream.Msg()
	}
	if err := stream.Err(); err != nil {
		return nil, err
	}
	return connect.NewResponse(response), nil
}

func (connectService) Chat(_ context.Context, stream *connect.BidiStream[coveragev1.Everything, coveragev1.Everything]) error {
	for {
		message, err := stream.Receive()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		if err := stream.Send(message); err != nil {
			return err
		}
	}
}

func (connectService) Fail(_ context.Context, request *connect.Request[interopv1.FailRequest]) (*connect.Response[coveragev1.Everything], error) {
	if request.Msg.Code < codeMin || request.Msg.Code > codeMax {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("code must be between 1 and 16"))
	}
	failure := connect.NewError(connect.Code(request.Msg.Code), errors.New(request.Msg.Message))
	detail, err := connect.NewErrorDetail(request.Msg)
	if err != nil {
		return nil, err
	}
	failure.AddDetail(detail)
	return nil, failure
}

func (connectService) Inspect(ctx context.Context, request *connect.Request[interopv1.InspectRequest]) (*connect.Response[interopv1.InspectResponse], error) {
	timeout, hasTimeout := remaining(ctx)
	response := connect.NewResponse(inspected(request.Header(), timeout, hasTimeout))
	for name, values := range request.Header() {
		if !strings.HasPrefix(strings.ToLower(name), inspectedPrefix) {
			continue
		}
		for _, value := range values {
			response.Header().Add(name, value)
			response.Trailer().Add(name, value)
		}
	}
	return response, nil
}

type grpcService struct {
	interopv1.UnimplementedInteropServiceServer
}

func (grpcService) Echo(_ context.Context, request *coveragev1.Everything) (*coveragev1.Everything, error) {
	return request, nil
}

func (grpcService) EchoGet(_ context.Context, request *coveragev1.Everything) (*coveragev1.Everything, error) {
	return request, nil
}

func (grpcService) Repeat(request *interopv1.RepeatRequest, stream grpc.ServerStreamingServer[coveragev1.Everything]) error {
	if err := checkCount(request.Count); err != nil {
		return status.Error(codes.OutOfRange, err.Error())
	}
	message := request.Message
	if message == nil {
		message = &coveragev1.Everything{}
	}
	for range request.Count {
		if err := stream.Send(message); err != nil {
			return err
		}
	}
	return nil
}

func (grpcService) Collect(stream grpc.ClientStreamingServer[coveragev1.Everything, interopv1.CollectResponse]) error {
	response := &interopv1.CollectResponse{}
	for {
		message, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return stream.SendAndClose(response)
		}
		if err != nil {
			return err
		}
		response.Count++
		response.Last = message
	}
}

func (grpcService) Chat(stream grpc.BidiStreamingServer[coveragev1.Everything, coveragev1.Everything]) error {
	for {
		message, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		if err := stream.Send(message); err != nil {
			return err
		}
	}
}

func (grpcService) Fail(_ context.Context, request *interopv1.FailRequest) (*coveragev1.Everything, error) {
	if request.Code < codeMin || request.Code > codeMax {
		return nil, status.Error(codes.InvalidArgument, "code must be between 1 and 16")
	}
	failure, err := status.New(codes.Code(request.Code), request.Message).WithDetails(request)
	if err != nil {
		return nil, err
	}
	return nil, failure.Err()
}

func (grpcService) Inspect(ctx context.Context, _ *interopv1.InspectRequest) (*interopv1.InspectResponse, error) {
	incoming, _ := metadata.FromIncomingContext(ctx)
	timeout, hasTimeout := remaining(ctx)
	sent := metadata.MD{}
	for name, values := range incoming {
		if strings.HasPrefix(name, inspectedPrefix) {
			sent[name] = values
		}
	}
	if err := grpc.SetHeader(ctx, sent); err != nil {
		return nil, err
	}
	if err := grpc.SetTrailer(ctx, sent); err != nil {
		return nil, err
	}
	return inspected(incoming, timeout, hasTimeout), nil
}
