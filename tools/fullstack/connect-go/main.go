// Command connect-go is the full-stack check's OTLP receiver on connect-go (design §8 step 31,
// decision 46). It serves OpenTelemetry's TraceService/Export over TLS with the test identity, h2
// and HTTP/1.1 picked by ALPN, decodes each export, counts its spans, and drops it, as
// tools/otlp_sink does. `GET /sink/count` answers `requests <n> spans <n>`, as the sink's does.
// It reads exports in gzip, zstd and brotli (compression.go).
//
//	connect-go <port> <chain> <key> [validate] [cleartext]
//
// With `validate`, it first checks each export against the rules of tools/fullstack/validate's
// schema with protovalidate-go, as `otlp-sink-validate` does, and refuses one that breaks a rule
// with `invalid_argument`. With `cleartext`, it serves h2 with prior knowledge and HTTP/1.1, with
// no TLS, for the cleartext climb.
package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"os"
	"sync/atomic"
	"time"

	"buf.build/go/protovalidate"
	"connectrpc.com/connect"

	collectorv1 "github.com/c4milo/connect-zig/tools/fullstack/connect-go/gen/opentelemetry/proto/collector/trace/v1"
	"github.com/c4milo/connect-zig/tools/fullstack/connect-go/gen/opentelemetry/proto/collector/trace/v1/tracev1connect"
)

// The time a connection may take to send a request's headers, as net/http asks a server to
// bound it.
const readHeaderTimeout = 10 * time.Second

func main() {
	words, ok := wordsOf(os.Args)
	if !ok {
		fmt.Fprintln(os.Stderr, "usage: connect-go <port> <chain> <key> [validate] [cleartext]")
		os.Exit(2)
	}
	identity, err := tls.LoadX509KeyPair(os.Args[2], os.Args[3])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:"+os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	sink := &receiver{}
	if words["validate"] {
		if sink.validator, err = protovalidate.New(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
	}
	mux := http.NewServeMux()
	mux.Handle(tracev1connect.NewTraceServiceHandler(sink, compressions()))
	mux.HandleFunc("GET /sink/count", func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("content-type", "text/plain")
		fmt.Fprintf(writer, "requests %d spans %d\n", sink.requests.Load(), sink.spans.Load())
	})
	server := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: readHeaderTimeout,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{identity}, NextProtos: []string{"h2", "http/1.1"}},
	}
	fmt.Printf("listening on port %d\n", listener.Addr().(*net.TCPAddr).Port)
	if words["cleartext"] {
		server.Protocols = new(http.Protocols)
		server.Protocols.SetHTTP1(true)
		server.Protocols.SetUnencryptedHTTP2(true)
		fmt.Fprintln(os.Stderr, server.Serve(listener))
	} else {
		fmt.Fprintln(os.Stderr, server.ServeTLS(listener, "", ""))
	}
	os.Exit(1)
}

// wordsOf returns the words after the key, and whether each is one the receiver knows.
func wordsOf(args []string) (map[string]bool, bool) {
	if len(args) < 4 {
		return nil, false
	}
	words := map[string]bool{}
	for _, word := range args[4:] {
		if word != "validate" && word != "cleartext" {
			return nil, false
		}
		words[word] = true
	}
	return words, true
}

// receiver counts the exports and the spans it took.
type receiver struct {
	requests atomic.Int64
	spans    atomic.Int64
	// The validator of each export, or nil when the receiver checks no rule.
	validator protovalidate.Validator
}

func (r *receiver) Export(_ context.Context, request *connect.Request[collectorv1.ExportTraceServiceRequest]) (*connect.Response[collectorv1.ExportTraceServiceResponse], error) {
	if r.validator != nil {
		if err := r.validator.Validate(request.Msg); err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, err)
		}
	}
	var spans int64
	for _, resource := range request.Msg.GetResourceSpans() {
		for _, scope := range resource.GetScopeSpans() {
			spans += int64(len(scope.GetSpans()))
		}
	}
	r.requests.Add(1)
	r.spans.Add(spans)
	return connect.NewResponse(&collectorv1.ExportTraceServiceResponse{}), nil
}
