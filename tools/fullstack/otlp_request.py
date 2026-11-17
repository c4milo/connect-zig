#!/usr/bin/env python3
"""Writes the OTLP trace export of tools/fullstack_check.sh (design §8 step 28).

    tools/fullstack/otlp_request.py <buf> <spans> <out.grpc>

The request holds one resource and one scope, as one service's SDK exports them, and <spans>
spans of an HTTP server's instrumentation, each with the attributes of OpenTelemetry's HTTP
semantic conventions. Every value comes from the span's index, so each run writes the same
request. The script writes it in proto3 JSON, and `buf convert` encodes it with Go's runtime, so
connect-zig encodes none of the octets it reads. <out.grpc> holds the encoding in gRPC's
Length-Prefixed-Message, as h2load sends it.
"""
import base64
import json
import subprocess
import sys

buf, spans, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
# The start of the first span, in nanoseconds since 1970: 2026-11-16 00:00:00 UTC.
start_ns = 1_794_787_200_000_000_000
# Each span starts 1 ms after the one before it, and lasts 250 µs past its index's share.
step_ns = 1_000_000
duration_ns = 250_000
routes = ["/api/orders/{id}", "/api/carts/{id}", "/api/users/{id}/profile", "/healthz"]


def octets(index, length, salt):
    """`length` octets that depend on `index` alone, in proto3 JSON's base64."""
    value = bytes((index * 131 + salt * 17 + k * 29) % 256 for k in range(length))
    return base64.b64encode(value).decode()


def text(key, value):
    return {"key": key, "value": {"stringValue": value}}


def number(key, value):
    # proto3 JSON writes an int64 as a string ("JSON Mapping", int64).
    return {"key": key, "value": {"intValue": str(value)}}


def span(index):
    route = routes[index % len(routes)]
    path = route.replace("{id}", str(1000 + index))
    begin = start_ns + index * step_ns
    return {
        # The spans of one trace share its ID, eight spans to a trace.
        "traceId": octets(index // 8, 16, 1),
        "spanId": octets(index, 8, 2),
        "parentSpanId": octets(index - 1, 8, 2) if index % 8 else "",
        "name": "GET " + route,
        "kind": "SPAN_KIND_SERVER",
        "startTimeUnixNano": str(begin),
        "endTimeUnixNano": str(begin + duration_ns + index * 1000),
        "attributes": [
            text("http.request.method", "GET"),
            text("http.route", route),
            number("http.response.status_code", 200),
            text("url.path", path),
            text("url.scheme", "https"),
            text("server.address", "checkout.internal"),
            number("server.port", 8443),
            text("network.protocol.version", "2"),
            text("user_agent.original", "checkout-client/1.4.2"),
        ],
        "status": {},
    }


request = {
    "resourceSpans": [{
        "resource": {"attributes": [
            text("service.name", "checkout"),
            text("service.version", "1.4.2"),
            text("host.name", "node-7"),
            text("telemetry.sdk.language", "go"),
            text("telemetry.sdk.name", "opentelemetry"),
            text("telemetry.sdk.version", "1.38.0"),
        ]},
        "scopeSpans": [{
            "scope": {"name": "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp", "version": "0.63.0"},
            "spans": [span(index) for index in range(spans)],
        }],
    }],
}
with open(out + ".json", "w") as file:
    json.dump(request, file)
subprocess.run([buf, "convert", "examples/otlp/proto",
                "--type", "opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest",
                "--from", out + ".json#format=json", "--to", out + ".binpb#format=binpb"], check=True)
encoded = open(out + ".binpb", "rb").read()
# gRPC over HTTP/2, "Requests": a Length-Prefixed-Message is a Compressed-Flag of 0, then the
# Message-Length in four octets, big-endian, then the message.
with open(out, "wb") as file:
    file.write(b"\0" + len(encoded).to_bytes(4, "big") + encoded)
