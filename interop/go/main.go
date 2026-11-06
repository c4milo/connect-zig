// The Go interop client: connect-go in Connect, gRPC and gRPC-Web, and grpc-go in gRPC, against
// connect-zig's server. interop/README.md names the scenarios and the output.
//
//	go run . <base-url> <cases-dir> <ca>
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"connectrpc.com/connect"
	"golang.org/x/net/http2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/encoding/gzip"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	coveragev1 "github.com/c4milo/connect-zig/interop/go/gen/coverage/v1"
	interopv1 "github.com/c4milo/connect-zig/interop/go/gen/interop/v1"
	"github.com/c4milo/connect-zig/interop/go/gen/interop/v1/interopv1connect"
)

const (
	client      = "go"
	header      = "x-interop-client"
	repeatCount = 3
	failCode    = 5
	failMessage = "gone"
	timeout     = 5 * time.Second
	callTimeout = 10 * time.Second
	// grpc-core rounds a deadline up to the next 10 ms (interop/README.md).
	timeoutMaxMS = 5010
)

// A case of examples/testdata/coverage: its name and its message.
type testCase struct {
	name    string
	message *coveragev1.Everything
}

var failures int

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: go run . <base-url> <cases-dir> <ca>")
		os.Exit(2)
	}
	base := os.Args[1]
	cases, err := readCases(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	trusted, err := trust(os.Args[3])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	// The server picks h2 or h11 by ALPN, as each transport offers one.
	h2 := &http.Client{Transport: &http2.Transport{TLSClientConfig: trusted}}
	h1Config := trusted.Clone()
	h1Config.NextProtos = []string{"http/1.1"}
	h1 := &http.Client{Transport: &http.Transport{TLSClientConfig: h1Config}}
	for _, run := range []struct {
		protocol string
		http     *http.Client
		options  []connect.ClientOption
		duplex   bool
		get      bool
	}{
		{"connect-proto", h2, nil, true, true},
		{"connect-json", h2, []connect.ClientOption{connect.WithProtoJSON()}, true, true},
		{"connect-h1", h1, nil, false, true},
		{"grpc", h2, []connect.ClientOption{connect.WithGRPC()}, true, false},
		{"grpc-web", h2, []connect.ClientOption{connect.WithGRPCWeb()}, true, false},
	} {
		c := connectRun{protocol: run.protocol, base: base, http: run.http, options: run.options}
		c.all(cases, run.duplex, run.get)
	}
	grpcRun(base, cases, trusted)
	if failures > 0 {
		os.Exit(1)
	}
}

// trust reads the server's CA, the test identity's, from a PEM file.
func trust(path string) (*tls.Config, error) {
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("%s holds no certificate", path)
	}
	return &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS13}, nil
}

func readCases(directory string) ([]testCase, error) {
	paths, err := filepath.Glob(filepath.Join(directory, "*.binpb"))
	if err != nil || len(paths) == 0 {
		return nil, fmt.Errorf("no cases in %s", directory)
	}
	sort.Strings(paths)
	var cases []testCase
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		message := &coveragev1.Everything{}
		if err := proto.Unmarshal(data, message); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		cases = append(cases, testCase{strings.TrimSuffix(filepath.Base(path), ".binpb"), message})
	}
	return cases, nil
}

func report(protocol, scenario string, err error) {
	if err == nil {
		fmt.Printf("ok: %s %s %s\n", client, protocol, scenario)
		return
	}
	failures++
	fmt.Printf("FAIL: %s %s %s: %v\n", client, protocol, scenario, err)
}

// same says whether two messages write the same octets, which also holds for NaN.
func same(want, got proto.Message) error {
	options := proto.MarshalOptions{Deterministic: true}
	wanted, err := options.Marshal(want)
	if err != nil {
		return err
	}
	gotten, err := options.Marshal(got)
	if err != nil {
		return err
	}
	if !bytes.Equal(wanted, gotten) {
		return fmt.Errorf("the answer differs: wanted %d octets, got %d", len(wanted), len(gotten))
	}
	return nil
}

func context5() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), callTimeout)
}

type connectRun struct {
	protocol string
	base     string
	http     *http.Client
	options  []connect.ClientOption
}

func (c connectRun) client(extra ...connect.ClientOption) interopv1connect.InteropServiceClient {
	return interopv1connect.NewInteropServiceClient(c.http, c.base, append(append([]connect.ClientOption{}, c.options...), extra...)...)
}

func (c connectRun) all(cases []testCase, duplex, get bool) {
	plain := c.client()
	gzipped := c.client(connect.WithSendGzip(), connect.WithCompressMinBytes(0))
	viaGet := c.client(connect.WithHTTPGet())
	for _, each := range cases {
		report(c.protocol, "echo "+each.name, c.echo(plain.Echo, each.message))
		report(c.protocol, "echo-gzip "+each.name, c.echo(gzipped.Echo, each.message))
		if get {
			report(c.protocol, "echo-get "+each.name, c.echo(viaGet.EchoGet, each.message))
		}
	}
	report(c.protocol, "repeat", c.repeat(plain, cases[len(cases)-1].message))
	report(c.protocol, "collect", c.collect(plain, cases))
	if duplex {
		report(c.protocol, "chat", c.chat(plain, cases))
	}
	report(c.protocol, "fail", c.fail(plain))
	report(c.protocol, "inspect", c.inspect(plain))
}

type unary func(context.Context, *connect.Request[coveragev1.Everything]) (*connect.Response[coveragev1.Everything], error)

func (c connectRun) echo(call unary, message *coveragev1.Everything) error {
	ctx, cancel := context5()
	defer cancel()
	response, err := call(ctx, connect.NewRequest(message))
	if err != nil {
		return err
	}
	return same(message, response.Msg)
}

func (c connectRun) repeat(service interopv1connect.InteropServiceClient, message *coveragev1.Everything) error {
	ctx, cancel := context5()
	defer cancel()
	stream, err := service.Repeat(ctx, connect.NewRequest(&interopv1.RepeatRequest{Message: message, Count: repeatCount}))
	if err != nil {
		return err
	}
	count := 0
	for stream.Receive() {
		if err := same(message, stream.Msg()); err != nil {
			return err
		}
		count++
	}
	if err := stream.Err(); err != nil {
		return err
	}
	if count != repeatCount {
		return fmt.Errorf("got %d messages, wanted %d", count, repeatCount)
	}
	return nil
}

func (c connectRun) collect(service interopv1connect.InteropServiceClient, cases []testCase) error {
	ctx, cancel := context5()
	defer cancel()
	stream := service.Collect(ctx)
	for _, each := range cases {
		if err := stream.Send(each.message); err != nil {
			return err
		}
	}
	response, err := stream.CloseAndReceive()
	if err != nil {
		return err
	}
	if int(response.Msg.Count) != len(cases) {
		return fmt.Errorf("counted %d, sent %d", response.Msg.Count, len(cases))
	}
	return same(cases[len(cases)-1].message, response.Msg.Last)
}

// chat sends each case only after the answer to the one before arrived: full-duplex.
func (c connectRun) chat(service interopv1connect.InteropServiceClient, cases []testCase) error {
	ctx, cancel := context5()
	defer cancel()
	stream := service.Chat(ctx)
	for _, each := range cases {
		if err := stream.Send(each.message); err != nil {
			return err
		}
		answer, err := stream.Receive()
		if err != nil {
			return err
		}
		if err := same(each.message, answer); err != nil {
			return fmt.Errorf("%s: %w", each.name, err)
		}
	}
	if err := stream.CloseRequest(); err != nil {
		return err
	}
	if _, err := stream.Receive(); !errors.Is(err, io.EOF) {
		return fmt.Errorf("wanted the end of the stream, got %v", err)
	}
	return stream.CloseResponse()
}

func (c connectRun) fail(service interopv1connect.InteropServiceClient) error {
	ctx, cancel := context5()
	defer cancel()
	request := &interopv1.FailRequest{Code: failCode, Message: failMessage}
	_, err := service.Fail(ctx, connect.NewRequest(request))
	var failure *connect.Error
	if !errors.As(err, &failure) {
		return fmt.Errorf("wanted a Connect error, got %v", err)
	}
	if failure.Code() != connect.CodeNotFound || failure.Message() != failMessage {
		return fmt.Errorf("got %v %q", failure.Code(), failure.Message())
	}
	return oneDetail(failure.Details(), request)
}

func oneDetail(details []*connect.ErrorDetail, request *interopv1.FailRequest) error {
	if len(details) != 1 {
		return fmt.Errorf("got %d details, wanted 1", len(details))
	}
	value, err := details[0].Value()
	if err != nil {
		return err
	}
	return same(request, value)
}

func (c connectRun) inspect(service interopv1connect.InteropServiceClient) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	request := connect.NewRequest(&interopv1.InspectRequest{})
	request.Header().Set(header, client)
	response, err := service.Inspect(ctx, request)
	if err != nil {
		return err
	}
	if err := inspected(response.Msg); err != nil {
		return err
	}
	if response.Header().Get(header) != client {
		return fmt.Errorf("no response header %s", header)
	}
	if response.Trailer().Get(header) != client {
		return fmt.Errorf("no trailer %s", header)
	}
	return nil
}

func inspected(response *interopv1.InspectResponse) error {
	if response.TimeoutMs < 1 || response.TimeoutMs > timeoutMaxMS {
		return fmt.Errorf("the server saw a timeout of %d ms", response.TimeoutMs)
	}
	line := header + ": " + client
	for _, seen := range response.Headers {
		if strings.EqualFold(seen, line) {
			return nil
		}
	}
	return fmt.Errorf("the server saw headers %v", response.Headers)
}

// grpcRun runs the scenarios through grpc-go, Google's own gRPC.
func grpcRun(base string, cases []testCase, trusted *tls.Config) {
	const protocol = "grpc-go"
	origin, err := url.Parse(base)
	if err != nil {
		report(protocol, "connect", err)
		return
	}
	connection, err := grpc.NewClient(origin.Host, grpc.WithTransportCredentials(credentials.NewTLS(trusted.Clone())))
	if err != nil {
		report(protocol, "connect", err)
		return
	}
	defer connection.Close()
	service := interopv1.NewInteropServiceClient(connection)
	for _, each := range cases {
		report(protocol, "echo "+each.name, grpcEcho(service, each.message))
		report(protocol, "echo-gzip "+each.name, grpcEcho(service, each.message, grpc.UseCompressor(gzip.Name)))
	}
	report(protocol, "repeat", grpcRepeat(service, cases[len(cases)-1].message))
	report(protocol, "collect", grpcCollect(service, cases))
	report(protocol, "chat", grpcChat(service, cases))
	report(protocol, "fail", grpcFail(service))
	report(protocol, "inspect", grpcInspect(service))
}

func grpcEcho(service interopv1.InteropServiceClient, message *coveragev1.Everything, options ...grpc.CallOption) error {
	ctx, cancel := context5()
	defer cancel()
	answer, err := service.Echo(ctx, message, options...)
	if err != nil {
		return err
	}
	return same(message, answer)
}

func grpcRepeat(service interopv1.InteropServiceClient, message *coveragev1.Everything) error {
	ctx, cancel := context5()
	defer cancel()
	stream, err := service.Repeat(ctx, &interopv1.RepeatRequest{Message: message, Count: repeatCount})
	if err != nil {
		return err
	}
	count := 0
	for {
		answer, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if err := same(message, answer); err != nil {
			return err
		}
		count++
	}
	if count != repeatCount {
		return fmt.Errorf("got %d messages, wanted %d", count, repeatCount)
	}
	return nil
}

func grpcCollect(service interopv1.InteropServiceClient, cases []testCase) error {
	ctx, cancel := context5()
	defer cancel()
	stream, err := service.Collect(ctx)
	if err != nil {
		return err
	}
	for _, each := range cases {
		if err := stream.Send(each.message); err != nil {
			return err
		}
	}
	response, err := stream.CloseAndRecv()
	if err != nil {
		return err
	}
	if int(response.Count) != len(cases) {
		return fmt.Errorf("counted %d, sent %d", response.Count, len(cases))
	}
	return same(cases[len(cases)-1].message, response.Last)
}

func grpcChat(service interopv1.InteropServiceClient, cases []testCase) error {
	ctx, cancel := context5()
	defer cancel()
	stream, err := service.Chat(ctx)
	if err != nil {
		return err
	}
	for _, each := range cases {
		if err := stream.Send(each.message); err != nil {
			return err
		}
		answer, err := stream.Recv()
		if err != nil {
			return err
		}
		if err := same(each.message, answer); err != nil {
			return fmt.Errorf("%s: %w", each.name, err)
		}
	}
	if err := stream.CloseSend(); err != nil {
		return err
	}
	if _, err := stream.Recv(); !errors.Is(err, io.EOF) {
		return fmt.Errorf("wanted the end of the stream, got %v", err)
	}
	return nil
}

func grpcFail(service interopv1.InteropServiceClient) error {
	ctx, cancel := context5()
	defer cancel()
	request := &interopv1.FailRequest{Code: failCode, Message: failMessage}
	_, err := service.Fail(ctx, request)
	failure, ok := status.FromError(err)
	if !ok || failure.Code() != codes.NotFound || failure.Message() != failMessage {
		return fmt.Errorf("got %v", err)
	}
	details := failure.Details()
	if len(details) != 1 {
		return fmt.Errorf("got %d details, wanted 1", len(details))
	}
	detail, ok := details[0].(proto.Message)
	if !ok {
		return fmt.Errorf("the detail is %v", details[0])
	}
	return same(request, detail)
}

func grpcInspect(service interopv1.InteropServiceClient) error {
	ctx, cancel := context.WithTimeout(metadata.AppendToOutgoingContext(context.Background(), header, client), timeout)
	defer cancel()
	var headers, trailers metadata.MD
	response, err := service.Inspect(ctx, &interopv1.InspectRequest{}, grpc.Header(&headers), grpc.Trailer(&trailers))
	if err != nil {
		return err
	}
	if err := inspected(response); err != nil {
		return err
	}
	if values := headers.Get(header); len(values) != 1 || values[0] != client {
		return fmt.Errorf("response headers %v", headers)
	}
	if values := trailers.Get(header); len(values) != 1 || values[0] != client {
		return fmt.Errorf("trailers %v", trailers)
	}
	return nil
}
