// The OpenTelemetry client of connect-zig's OTLP receiver (decision 40): it exports spans with
// OpenTelemetry's Go SDK and its gRPC exporter, the way an instrumented Go program does, and
// then reads them back with otlpstore.v1.SpanStore/Received.
//
//	otel <base-url> <ca>
//
// The tracer provider sends each span both to the exporter and to an in-memory recorder, so the
// program knows each span as the SDK ended it. It compares each with the span the receiver
// kept, field by field, and prints one line for each check:
//
//	ok: otel grpc <check>
//	FAIL: otel grpc <check>: <what differed>
//
// It exits 0 when every line is ok.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net/url"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
	collectorpb "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	commonpb "go.opentelemetry.io/proto/otlp/common/v1"
	tracepb "go.opentelemetry.io/proto/otlp/trace/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

const (
	serviceName  = "interop-otel"
	scopeName    = "connect-zig/interop/otel"
	scopeVersion = "1.0.0"
	callTimeout  = 30 * time.Second
)

var failed = false

// exportErrors holds what the SDK reported while it exported: a synchronous exporter logs its
// errors through the global handler, and returns none to the code that ends a span.
var exportErrors []error

func report(check string, problem string) {
	if problem == "" {
		fmt.Printf("ok: otel grpc %s\n", check)
		return
	}
	failed = true
	fmt.Printf("FAIL: otel grpc %s: %s\n", check, problem)
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: otel <base-url> <ca>")
		os.Exit(2)
	}
	base, err := url.Parse(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	creds, err := credentialsOf(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), callTimeout)
	defer cancel()
	recorded, err := exportSpans(ctx, base.Host, creds)
	report("export", errorText(err))
	if err == nil {
		got, err := received(ctx, base.Host, creds)
		report("received", errorText(err))
		if err == nil {
			compare(recorded, got)
		}
	}
	if failed {
		os.Exit(1)
	}
}

func errorText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// credentialsOf trusts the CA of the file at path alone, and judges the server by "localhost".
func credentialsOf(path string) (credentials.TransportCredentials, error) {
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("no certificate in %s", path)
	}
	return credentials.NewTLS(&tls.Config{RootCAs: pool, ServerName: "localhost", MinVersion: tls.VersionTLS13}), nil
}

// exportSpans runs a small trace through the SDK, which exports each span as it ends, with gzip,
// and returns the spans as the SDK ended them.
func exportSpans(ctx context.Context, host string, creds credentials.TransportCredentials) ([]sdktrace.ReadOnlySpan, error) {
	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(host),
		otlptracegrpc.WithTLSCredentials(creds),
		otlptracegrpc.WithCompressor("gzip"),
	)
	if err != nil {
		return nil, err
	}
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) { exportErrors = append(exportErrors, err) }))
	recorder := tracetest.NewSpanRecorder()
	provider := sdktrace.NewTracerProvider(
		sdktrace.WithSyncer(exporter),
		sdktrace.WithSpanProcessor(recorder),
		sdktrace.WithResource(resource.NewSchemaless(attribute.String("service.name", serviceName))),
	)
	tracer := provider.Tracer(scopeName, trace.WithInstrumentationVersion(scopeVersion))
	traceSession(ctx, tracer)
	if err := provider.ForceFlush(ctx); err != nil {
		return nil, err
	}
	if err := provider.Shutdown(ctx); err != nil {
		return nil, err
	}
	if len(exportErrors) > 0 {
		return nil, fmt.Errorf("the exporter reported %d errors, the first: %w", len(exportErrors), exportErrors[0])
	}
	return recorder.Ended(), nil
}

// traceSession is the instrumented code: a checkout with a query, a charge that fails, and a
// receipt linked to the checkout. Its attributes hold every kind the API has.
func traceSession(ctx context.Context, tracer trace.Tracer) {
	ctx, checkout := tracer.Start(ctx, "POST /checkout",
		trace.WithSpanKind(trace.SpanKindServer),
		trace.WithAttributes(
			attribute.String("http.request.method", "POST"),
			attribute.Int64("http.response.status_code", 200),
			attribute.Bool("user.signed_in", true),
			attribute.Float64("cart.discount", 0.15),
			attribute.StringSlice("cart.items", []string{"book", "pen"}),
			attribute.Int64Slice("cart.quantities", []int64{1, 3}),
			attribute.BoolSlice("cart.gifts", []bool{false, true}),
			attribute.Float64Slice("cart.prices", []float64{12.5, 1.25}),
		))
	checkout.AddEvent("cart loaded", trace.WithAttributes(attribute.Int("cart.size", 2)))
	_, query := tracer.Start(ctx, "SELECT cart", trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(attribute.String("db.system", "sqlite")))
	query.End()
	_, charge := tracer.Start(ctx, "charge card", trace.WithSpanKind(trace.SpanKindClient))
	charge.SetStatus(codes.Error, "card declined")
	charge.End()
	checkout.SetStatus(codes.Ok, "")
	checkout.End()
	_, receipt := tracer.Start(context.Background(), "send receipt",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithLinks(trace.Link{SpanContext: checkout.SpanContext(), Attributes: []attribute.KeyValue{attribute.String("link.reason", "checkout")}}))
	receipt.End()
}

// received reads back every export the receiver kept, as one request.
func received(ctx context.Context, host string, creds credentials.TransportCredentials) (*collectorpb.ExportTraceServiceRequest, error) {
	conn, err := grpc.NewClient(host, grpc.WithTransportCredentials(creds))
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	got := &collectorpb.ExportTraceServiceRequest{}
	err = conn.Invoke(ctx, "/otlpstore.v1.SpanStore/Received", &emptypb.Empty{}, got)
	return got, err
}

// keptSpan is a span the receiver kept, with the resource and the scope it came under.
type keptSpan struct {
	span     *tracepb.Span
	service  string
	scope    string
	version  string
	resource int
}

func compare(recorded []sdktrace.ReadOnlySpan, got *collectorpb.ExportTraceServiceRequest) {
	kept := map[string]keptSpan{}
	for index, resourceSpans := range got.GetResourceSpans() {
		service := ""
		for _, kv := range resourceSpans.GetResource().GetAttributes() {
			if kv.GetKey() == "service.name" {
				service = kv.GetValue().GetStringValue()
			}
		}
		for _, scopeSpans := range resourceSpans.GetScopeSpans() {
			for _, span := range scopeSpans.GetSpans() {
				kept[string(span.GetSpanId())] = keptSpan{span, service, scopeSpans.GetScope().GetName(), scopeSpans.GetScope().GetVersion(), index}
			}
		}
	}
	if len(kept) < len(recorded) {
		report("span count", fmt.Sprintf("the receiver kept %d spans, the SDK ended %d", len(kept), len(recorded)))
	} else {
		report("span count", "")
	}
	for _, want := range recorded {
		id := want.SpanContext().SpanID()
		got, ok := kept[string(id[:])]
		if !ok {
			report("span "+want.Name(), "the receiver kept no span with its ID")
			continue
		}
		report("span "+want.Name(), differences(want, got))
	}
}

// differences names the first field of `got` that differs from the span the SDK ended.
func differences(want sdktrace.ReadOnlySpan, got keptSpan) string {
	span := got.span
	traceID := want.SpanContext().TraceID()
	parentID := want.Parent().SpanID()
	switch {
	case got.service != serviceName:
		return fmt.Sprintf("resource service.name %q", got.service)
	case got.scope != scopeName || got.version != scopeVersion:
		return fmt.Sprintf("scope %q %q", got.scope, got.version)
	case string(span.GetTraceId()) != string(traceID[:]):
		return "trace ID"
	case want.Parent().IsValid() && string(span.GetParentSpanId()) != string(parentID[:]):
		return "parent span ID"
	case span.GetName() != want.Name():
		return fmt.Sprintf("name %q", span.GetName())
	case int32(span.GetKind()) != int32(want.SpanKind()):
		return fmt.Sprintf("kind %v", span.GetKind())
	case span.GetStartTimeUnixNano() != uint64(want.StartTime().UnixNano()) || span.GetEndTimeUnixNano() != uint64(want.EndTime().UnixNano()):
		return "start or end time"
	case !sameAttributes(want.Attributes(), span.GetAttributes()):
		return "attributes"
	case !sameEvents(want.Events(), span.GetEvents()):
		return "events"
	case !sameLinks(want.Links(), span.GetLinks()):
		return "links"
	case !sameStatus(want.Status(), span.GetStatus()):
		return fmt.Sprintf("status %v %q", span.GetStatus().GetCode(), span.GetStatus().GetMessage())
	}
	return ""
}

func sameAttributes(want []attribute.KeyValue, got []*commonpb.KeyValue) bool {
	if len(want) != len(got) {
		return false
	}
	byKey := map[string]*commonpb.AnyValue{}
	for _, kv := range got {
		byKey[kv.GetKey()] = kv.GetValue()
	}
	for _, kv := range want {
		if !proto.Equal(anyValueOf(kv.Value), byKey[string(kv.Key)]) {
			return false
		}
	}
	return true
}

// anyValueOf writes an attribute value as OTLP carries it (OTLP specification, "AnyValue").
func anyValueOf(value attribute.Value) *commonpb.AnyValue {
	switch value.Type() {
	case attribute.STRING:
		return &commonpb.AnyValue{Value: &commonpb.AnyValue_StringValue{StringValue: value.AsString()}}
	case attribute.INT64:
		return &commonpb.AnyValue{Value: &commonpb.AnyValue_IntValue{IntValue: value.AsInt64()}}
	case attribute.BOOL:
		return &commonpb.AnyValue{Value: &commonpb.AnyValue_BoolValue{BoolValue: value.AsBool()}}
	case attribute.FLOAT64:
		return &commonpb.AnyValue{Value: &commonpb.AnyValue_DoubleValue{DoubleValue: value.AsFloat64()}}
	}
	values := []*commonpb.AnyValue{}
	switch value.Type() {
	case attribute.STRINGSLICE:
		for _, item := range value.AsStringSlice() {
			values = append(values, anyValueOf(attribute.StringValue(item)))
		}
	case attribute.INT64SLICE:
		for _, item := range value.AsInt64Slice() {
			values = append(values, anyValueOf(attribute.Int64Value(item)))
		}
	case attribute.BOOLSLICE:
		for _, item := range value.AsBoolSlice() {
			values = append(values, anyValueOf(attribute.BoolValue(item)))
		}
	case attribute.FLOAT64SLICE:
		for _, item := range value.AsFloat64Slice() {
			values = append(values, anyValueOf(attribute.Float64Value(item)))
		}
	}
	return &commonpb.AnyValue{Value: &commonpb.AnyValue_ArrayValue{ArrayValue: &commonpb.ArrayValue{Values: values}}}
}

func sameEvents(want []sdktrace.Event, got []*tracepb.Span_Event) bool {
	if len(want) != len(got) {
		return false
	}
	for index, event := range want {
		kept := got[index]
		if kept.GetName() != event.Name || kept.GetTimeUnixNano() != uint64(event.Time.UnixNano()) || !sameAttributes(event.Attributes, kept.GetAttributes()) {
			return false
		}
	}
	return true
}

func sameLinks(want []sdktrace.Link, got []*tracepb.Span_Link) bool {
	if len(want) != len(got) {
		return false
	}
	for index, link := range want {
		kept := got[index]
		traceID := link.SpanContext.TraceID()
		spanID := link.SpanContext.SpanID()
		if string(kept.GetTraceId()) != string(traceID[:]) || string(kept.GetSpanId()) != string(spanID[:]) || !sameAttributes(link.Attributes, kept.GetAttributes()) {
			return false
		}
	}
	return true
}

// sameStatus compares a status the way the exporter writes it: OTLP's codes are the API's
// codes in another order, and a message goes with an error alone.
func sameStatus(want sdktrace.Status, got *tracepb.Status) bool {
	code := tracepb.Status_STATUS_CODE_UNSET
	switch want.Code {
	case codes.Ok:
		code = tracepb.Status_STATUS_CODE_OK
	case codes.Error:
		code = tracepb.Status_STATUS_CODE_ERROR
	}
	return got.GetCode() == code && got.GetMessage() == want.Description
}
