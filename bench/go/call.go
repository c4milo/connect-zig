// The routed calls: the counterpart of bench/call.zig. One unary call of a message through an
// http.ServeMux that routes it to connect-go's handler, in memory, with no socket, no framing and
// no TLS, as on the Zig side. The Zig side replays a request head it built once, into storage it
// reuses. So the timed calls here copy a request httptest built once, give it a new reader of the
// body, and write into one response writer whose header and body each call clears. The check of
// each reply runs a whole request and httptest's recorder, outside the timed calls.
//
// The mux holds 1, 16 or 256 routes, as bench/call.zig's tables do: the echo method's, then more
// methods of its service, then more services of as many methods. The calls never reach the other
// routes.
//
// The handler answers the message with itself. Its proto codec marshals deterministically, so a
// map's entries go in key order and each reply's octets equal its request's, as Zig's do.
// connect-go's own codec marshals a map in Go's random order.
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	benchv1 "github.com/c4milo/connect-zig/bench/go/gen/bench/v1"
)

// A protocol of the routed calls: the table's label, the request's content type, and the end of
// the name of the reply's file.
type callProtocol struct {
	label       string
	contentType string
	fileSuffix  string
	grpc        bool
}

var callProtocols = []callProtocol{
	{label: "Connect unary call", contentType: "application/proto", fileSuffix: "connect.reply"},
	{label: "gRPC unary call", contentType: "application/grpc+proto", fileSuffix: "grpc.reply", grpc: true},
}

// gRPC's "Length-Prefixed-Message": a flag octet, then the length in four octets.
const prefixLen = 5

// The sizes of the route tables the small message's calls run on, as bench/constants.zig's
// call_route_counts: each a square of services and methods.
var callRouteCounts = []int{1, 16, 256}

// deterministicCodec is connect-go's proto codec with deterministic marshaling.
type deterministicCodec struct{}

func (deterministicCodec) Name() string { return "proto" }

func (deterministicCodec) Marshal(message any) ([]byte, error) {
	return deterministic.Marshal(message.(proto.Message))
}

func (deterministicCodec) Unmarshal(data []byte, message any) error {
	return proto.Unmarshal(data, message.(proto.Message))
}

// echoHandler serves `Echo<name>` of bench.v1.Bench, which answers a message with itself.
func echoHandler[T any](name string) (string, http.Handler) {
	procedure := "/bench.v1.Bench/Echo" + name
	handler := connect.NewUnaryHandler(procedure, func(_ context.Context, request *connect.Request[T]) (*connect.Response[T], error) {
		return connect.NewResponse(request.Msg), nil
	}, connect.WithCodec(deterministicCodec{}))
	return procedure, handler
}

// echoMux routes `Echo<name>` of bench.v1.Bench in a table of `routes` routes, the paths of
// bench/call.zig's filler_path: `Filler<j>` of the echo method's service, then `Call<j>` of the
// services `bench.v1.Filler<i>`.
func echoMux[T any](name string, routes int) (string, http.Handler) {
	side := int(math.Sqrt(float64(routes)))
	if side*side != routes {
		panic("a route table is a square of services and methods")
	}
	procedure, handler := echoHandler[T](name)
	mux := http.NewServeMux()
	mux.Handle(procedure, handler)
	for index := 1; index < routes; index++ {
		filler := fmt.Sprintf("/bench.v1.Filler%02d/Call%02d", index/side, index%side)
		if index < side {
			filler = fmt.Sprintf("/bench.v1.Bench/Filler%02d", index)
		}
		mux.Handle(filler, connect.NewUnaryHandler(filler, func(_ context.Context, request *connect.Request[T]) (*connect.Response[T], error) {
			return connect.NewResponse(request.Msg), nil
		}, connect.WithCodec(deterministicCodec{})))
	}
	return procedure, mux
}

// A routed call of one message in one protocol, with the request the timed calls copy, the
// reader of its body and the response writer they reuse.
type routedCall struct {
	protocol  callProtocol
	procedure string
	handler   http.Handler
	body      []byte
	template  *http.Request
	reader    *bytes.Reader
	writer    *reusedWriter
}

func newRoutedCall(protocol callProtocol, procedure string, handler http.Handler, encoded []byte) *routedCall {
	body := encoded
	if protocol.grpc {
		body = make([]byte, prefixLen, prefixLen+len(encoded))
		binary.BigEndian.PutUint32(body[1:prefixLen], uint32(len(encoded)))
		body = append(body, encoded...)
	}
	c := &routedCall{protocol: protocol, procedure: procedure, handler: handler, body: body}
	c.template = c.request()
	c.reader = bytes.NewReader(body)
	c.writer = &reusedWriter{header: http.Header{}}
	return c
}

// request builds the call's request, as a server would parse it.
func (c *routedCall) request() *http.Request {
	request := httptest.NewRequest(http.MethodPost, c.procedure, bytes.NewReader(c.body))
	request.Header.Set("Content-Type", c.protocol.contentType)
	if c.protocol.grpc {
		// gRPC runs over HTTP/2 (PROTOCOL-HTTP2.md), and asks for trailers.
		request.ProtoMajor, request.ProtoMinor, request.Proto = 2, 0, "HTTP/2.0"
		request.Header.Set("Te", "trailers")
	}
	return request
}

// serve runs one call on a request of its own and returns the recorder that holds its response.
func (c *routedCall) serve() *httptest.ResponseRecorder {
	recorder := httptest.NewRecorder()
	c.handler.ServeHTTP(recorder, c.request())
	return recorder
}

// reusedWriter is a response writer that each timed call clears and writes again, as the Zig
// side writes each reply into the storage it reuses.
type reusedWriter struct {
	header http.Header
	body   bytes.Buffer
	status int
}

func (w *reusedWriter) Header() http.Header            { return w.header }
func (w *reusedWriter) WriteHeader(status int)         { w.status = status }
func (w *reusedWriter) Write(data []byte) (int, error) { return w.body.Write(data) }
func (w *reusedWriter) Flush()                         {}

// serveReused runs one call on a copy of the request built once, with the body read again from
// its start, into the reused writer, and returns the writer.
func (c *routedCall) serveReused() *reusedWriter {
	request := *c.template
	c.reader.Reset(c.body)
	request.Body = io.NopCloser(c.reader)
	clear(c.writer.header)
	c.writer.body.Reset()
	c.writer.status = http.StatusOK
	c.handler.ServeHTTP(c.writer, &request)
	return c.writer
}

// reply runs one call and checks that it answered 200 with its request's octets.
func (c *routedCall) reply() ([]byte, error) {
	recorder := c.serve()
	if recorder.Code != http.StatusOK {
		return nil, errors.New(c.protocol.label + ": HTTP " + http.StatusText(recorder.Code))
	}
	if c.protocol.grpc && recorder.Result().Trailer.Get("Grpc-Status") != "0" {
		return nil, errors.New(c.protocol.label + ": grpc-status " + recorder.Result().Trailer.Get("Grpc-Status"))
	}
	if !bytes.Equal(recorder.Body.Bytes(), c.body) {
		return nil, errors.New(c.protocol.label + ": the reply differs from the request")
	}
	return recorder.Body.Bytes(), nil
}

// runner times the calls on the reused request and writer, once a call on them has answered 200
// with the request's octets, as the checked call does.
func (c *routedCall) runner() (func(n uint64) error, error) {
	if writer := c.serveReused(); writer.status != http.StatusOK || !bytes.Equal(writer.body.Bytes(), c.body) {
		return nil, errors.New(c.protocol.label + ": the reused request's reply differs from the request")
	}
	return func(n uint64) error {
		for i := uint64(0); i < n; i++ {
			sink += uint64(c.serveReused().body.Len())
		}
		return nil
	}, nil
}

func (c *routedCall) write(directory, name string) error {
	reply, err := c.reply()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(directory, name+"."+c.protocol.fileSuffix), reply, 0o644)
}

// runCalls times the routed calls of the small and the medium message, each after its reply is
// checked, and writes each reply into `directory` when it is set. The small message's calls run
// in each table of callRouteCounts too, in bench/call_main.zig's order.
func runCalls(current settings, directory string, small, medium *message) error {
	smallProcedure, smallHandler := echoMux[benchv1.Small]("Small", 1)
	mediumProcedure, mediumHandler := echoMux[benchv1.Medium]("Medium", 1)
	type target struct {
		message   *message
		procedure string
		handler   http.Handler
		routes    int
	}
	targets := []target{
		{small, smallProcedure, smallHandler, 1},
		{medium, mediumProcedure, mediumHandler, 1},
	}
	for _, routes := range callRouteCounts[1:] {
		procedure, handler := echoMux[benchv1.Small]("Small", routes)
		targets = append(targets, target{small, procedure, handler, routes})
	}
	for _, t := range targets {
		for _, protocol := range callProtocols {
			if err := runCall(current, directory, t.message, t.procedure, t.handler, t.routes, protocol); err != nil {
				return err
			}
		}
	}
	return nil
}

// runCall checks, writes and times one routed call. A call in a table of more than one route
// names the count after its own name, as "Connect unary call, 16 routes", and writes no reply.
func runCall(current settings, directory string, m *message, procedure string, handler http.Handler, routes int, protocol callProtocol) error {
	c := newRoutedCall(protocol, procedure, handler, m.binary)
	if _, err := c.reply(); err != nil {
		return fmt.Errorf("%s: %w", m.name, err)
	}
	label := protocol.label
	if routes > 1 {
		label = fmt.Sprintf("%s, %d routes", protocol.label, routes)
	} else if directory != "" {
		if err := c.write(directory, m.name); err != nil {
			return err
		}
	}
	run, err := c.runner()
	if err != nil {
		return fmt.Errorf("%s, %s: %w", m.name, label, err)
	}
	ns, err := medianNs(current, run)
	if err != nil {
		return fmt.Errorf("%s, %s: %w", m.name, label, err)
	}
	size := len(c.body)
	megabytesPerSecond := float64(size) / ns * 1e9 / bytesPerMegabyte
	fmt.Printf("| %s | %s | %d | %.1f | %.1f |\n", m.name, label, size, ns, megabytesPerSecond)
	return nil
}
