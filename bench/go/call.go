// The routed calls: the counterpart of bench/call.zig. One unary call of a message through
// connect-go's handler, in memory: ServeHTTP on a request that httptest builds, with a recorder
// for the response. No socket, no framing and no TLS, as on the Zig side.
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

// A routed call of one message in one protocol.
type routedCall struct {
	protocol  callProtocol
	procedure string
	handler   http.Handler
	body      []byte
}

func newRoutedCall(protocol callProtocol, procedure string, handler http.Handler, encoded []byte) *routedCall {
	body := encoded
	if protocol.grpc {
		body = make([]byte, prefixLen, prefixLen+len(encoded))
		binary.BigEndian.PutUint32(body[1:prefixLen], uint32(len(encoded)))
		body = append(body, encoded...)
	}
	return &routedCall{protocol: protocol, procedure: procedure, handler: handler, body: body}
}

// serve runs one call and returns the recorder that holds its response.
func (c *routedCall) serve() *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, c.procedure, bytes.NewReader(c.body))
	request.Header.Set("Content-Type", c.protocol.contentType)
	if c.protocol.grpc {
		// gRPC runs over HTTP/2 (PROTOCOL-HTTP2.md), and asks for trailers.
		request.ProtoMajor, request.ProtoMinor, request.Proto = 2, 0, "HTTP/2.0"
		request.Header.Set("Te", "trailers")
	}
	recorder := httptest.NewRecorder()
	c.handler.ServeHTTP(recorder, request)
	return recorder
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

func (c *routedCall) runner() func(n uint64) error {
	return func(n uint64) error {
		for i := uint64(0); i < n; i++ {
			sink += uint64(c.serve().Body.Len())
		}
		return nil
	}
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
// checked, and writes each reply into `directory` when it is set.
func runCalls(current settings, directory string, small, medium *message) error {
	smallProcedure, smallHandler := echoHandler[benchv1.Small]("Small")
	mediumProcedure, mediumHandler := echoHandler[benchv1.Medium]("Medium")
	targets := []struct {
		message   *message
		procedure string
		handler   http.Handler
	}{
		{small, smallProcedure, smallHandler},
		{medium, mediumProcedure, mediumHandler},
	}
	for _, target := range targets {
		for _, protocol := range callProtocols {
			c := newRoutedCall(protocol, target.procedure, target.handler, target.message.binary)
			if _, err := c.reply(); err != nil {
				return fmt.Errorf("%s: %w", target.message.name, err)
			}
			if directory != "" {
				if err := c.write(directory, target.message.name); err != nil {
					return err
				}
			}
			ns, err := medianNs(current, c.runner())
			if err != nil {
				return fmt.Errorf("%s, %s: %w", target.message.name, protocol.label, err)
			}
			size := len(c.body)
			megabytesPerSecond := float64(size) / ns * 1e9 / bytesPerMegabyte
			fmt.Printf("| %s | %s | %d | %.1f | %.1f |\n", target.message.name, protocol.label, size, ns, megabytesPerSecond)
		}
	}
	return nil
}
