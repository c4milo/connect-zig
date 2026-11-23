#!/usr/bin/env python3
"""Writes an export of the production model of tools/fullstack/production.sh (decision 44).

    tools/fullstack/production_request.py <buf> <spans> <out.grpc> [<variant>]

The export is what a node's Collector agent forwards to a gateway: the spans of several pods,
each pod a resource with the attributes of OpenTelemetry's Kubernetes, cloud and host semantic
conventions. Its spans are HTTP server and client calls, gRPC calls, database queries and Kafka
sends, in traces of up to 8 spans. 2% of the spans are errors with an exception event, and 5%
carry an event of their own. A generator seeded by <spans> and <variant> chooses every value, so
each run writes the same octets. Variant 0, the default, is seeded by <spans> alone. The load sends
each class's variants in turn, so a decoder does not read the same octets on every call.

The script writes the export in proto3 JSON to <out.grpc>.json, for `buf curl`, and `buf convert`
encodes it with Go's runtime. <out.grpc> holds the encoding compressed with gzip at Go's default
level, 6, in gRPC's Length-Prefixed-Message with its Compressed-Flag set, as the Collector's otlp
exporter sends it by default.
"""

import base64
import gzip
import json
import pathlib
import random
import subprocess
import sys

# Pods in one export: one for each 64 spans, from 1 to 8.
pods_per_spans = 64
pods_max = 8
spans_per_trace = 8
error_share = 0.02
event_share = 0.05
# 2026-11-16 00:00:00 UTC, in nanoseconds since 1970.
start_ns = 1_794_787_200_000_000_000
services = ["channels", "messages", "search", "files", "notifications", "presence", "auth", "billing"]
routes = [
    "/api/conversations.history",
    "/api/chat.postMessage",
    "/api/users.info",
    "/api/files.upload",
    "/api/reactions.add",
    "/api/search.messages",
    "/api/conversations.list",
    "/api/team.info",
]
tables = ["messages", "channels", "users", "files", "reactions", "teams"]
topics = ["message-events", "presence-updates", "search-index", "audit-log"]
agents = [
    "Slack/4.41.105 (darwin; arm64) Electron/32.2.5",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0",
    "com.tinyspeck.chatlyio/24.11.10 (iPhone; iOS 18.1.1; Scale/3.00)",
]
# The frames of an error's stack trace.
stack_frames = 12


def stack_of(frames):
    """A Go stack trace of `frames` frames."""
    return "".join(
        f"main.(*Handler).serve{n}(0xc000{n:04x}, 0x{n * 4096:x})\n\t/src/app/handler.go:{100 + n}\n"
        for n in range(frames)
    )


stack = stack_of(stack_frames)


def octets(draw, length):
    return base64.b64encode(bytes(draw.randrange(256) for _ in range(length))).decode()


def text(key, value):
    return {"key": key, "value": {"stringValue": value}}


def number(key, value):
    # proto3 JSON writes an int64 as a string ("JSON Mapping", int64).
    return {"key": key, "value": {"intValue": str(value)}}


def resource(draw, pod):
    service = services[pod % len(services)]
    name = f"{service}-{draw.randrange(16**9):09x}-{draw.randrange(36**5):05x}"
    return {
        "attributes": [
            text("service.name", service),
            text("service.namespace", "slack"),
            text("service.version", f"2026.11.{draw.randrange(1, 17)}"),
            text("service.instance.id", octets(draw, 12)),
            text("deployment.environment.name", "production"),
            text("k8s.cluster.name", "prod-us-east-1-c7"),
            text("k8s.namespace.name", service),
            text("k8s.node.name", "ip-10-24-118-37.ec2.internal"),
            text("k8s.pod.name", name),
            text("k8s.pod.uid", octets(draw, 16)),
            text("k8s.deployment.name", service),
            text("container.name", service),
            text("container.id", octets(draw, 24)),
            text("host.name", "ip-10-24-118-37.ec2.internal"),
            text("host.arch", "amd64"),
            text("os.type", "linux"),
            text("cloud.provider", "aws"),
            text("cloud.platform", "aws_eks"),
            text("cloud.region", "us-east-1"),
            text("cloud.availability_zone", "us-east-1c"),
            text("telemetry.sdk.language", "go"),
            text("telemetry.sdk.name", "opentelemetry"),
            text("telemetry.sdk.version", "1.38.0"),
        ]
    }


def http_server(draw):
    route = draw.choice(routes)
    return (
        "SPAN_KIND_SERVER",
        f"POST {route}",
        [
            text("http.request.method", "POST"),
            text("http.route", route),
            text("url.path", route),
            text("url.scheme", "https"),
            number("http.response.status_code", 200),
            text("server.address", "slack.com"),
            number("server.port", 443),
            text("client.address", f"10.{draw.randrange(256)}.{draw.randrange(256)}.{draw.randrange(256)}"),
            text("network.protocol.version", "2"),
            text("user_agent.original", draw.choice(agents)),
            number("http.request.body.size", draw.randrange(200, 4000)),
            number("http.response.body.size", draw.randrange(200, 40000)),
        ],
    )


def http_client(draw):
    service = draw.choice(services)
    return (
        "SPAN_KIND_CLIENT",
        "POST",
        [
            text("http.request.method", "POST"),
            text("url.full", f"http://{service}.{service}.svc:8080/internal/v1/lookup"),
            text("server.address", f"{service}.{service}.svc"),
            number("server.port", 8080),
            number("http.response.status_code", 200),
            text("network.protocol.version", "1.1"),
        ],
    )


def grpc_call(draw):
    service = draw.choice(services)
    method = draw.choice(["Get", "List", "BatchGet", "Update"])
    return (
        draw.choice(["SPAN_KIND_SERVER", "SPAN_KIND_CLIENT"]),
        f"slack.{service}.v1.{service.title()}Service/{method}",
        [
            text("rpc.system", "grpc"),
            text("rpc.service", f"slack.{service}.v1.{service.title()}Service"),
            text("rpc.method", method),
            number("rpc.grpc.status_code", 0),
            text("server.address", f"{service}.{service}.svc"),
            number("server.port", 9090),
        ],
    )


def database(draw):
    table = draw.choice(tables)
    system = draw.choice(["mysql", "mysql", "redis"])
    query = (
        (
            f"SELECT id, team_id, channel_id, user_id, ts, text, edited_ts FROM {table} "
            f"WHERE team_id = ? AND channel_id = ? AND ts > ? ORDER BY ts DESC LIMIT ?"
        )
        if system == "mysql"
        else f"HGETALL {table}:?"
    )
    return (
        "SPAN_KIND_CLIENT",
        f"SELECT {table}" if system == "mysql" else "HGETALL",
        [
            text("db.system.name", system),
            text("db.namespace", f"shard_{draw.randrange(1024):04d}"),
            text("db.operation.name", "SELECT" if system == "mysql" else "HGETALL"),
            text("db.collection.name", table),
            text("db.query.text", query),
            text("server.address", f"{system}-{draw.randrange(64):02d}.db.internal"),
            number("server.port", 3306 if system == "mysql" else 6379),
        ],
    )


def kafka(draw):
    topic = draw.choice(topics)
    return (
        "SPAN_KIND_PRODUCER",
        f"send {topic}",
        [
            text("messaging.system", "kafka"),
            text("messaging.destination.name", topic),
            text("messaging.operation.type", "send"),
            text("messaging.operation.name", "send"),
            number("messaging.destination.partition.id", draw.randrange(64)),
            number("messaging.message.body.size", draw.randrange(100, 2000)),
            text("server.address", "kafka-0.kafka.internal"),
            number("server.port", 9092),
        ],
    )


# The kinds of span, and the share of each: HTTP server 35%, database 25%, gRPC 15%, HTTP client
# 15%, Kafka 10%.
kinds = [http_server] * 7 + [database] * 5 + [grpc_call] * 3 + [http_client] * 3 + [kafka] * 2


def span(draw, index, trace, parent, begin):
    kind, name, attributes = (http_server if index % spans_per_trace == 0 else draw.choice(kinds))(draw)
    duration = draw.randrange(200_000, 40_000_000)
    item = {
        "traceId": trace,
        "spanId": octets(draw, 8),
        "parentSpanId": parent,
        "name": name,
        "kind": kind,
        "flags": 1,
        "startTimeUnixNano": str(begin),
        "endTimeUnixNano": str(begin + duration),
        "attributes": attributes,
        "status": {},
    }
    if draw.random() < error_share:
        item["status"] = {"code": "STATUS_CODE_ERROR", "message": "context deadline exceeded"}
        item["events"] = [
            {
                "timeUnixNano": str(begin + duration),
                "name": "exception",
                "attributes": [
                    text("exception.type", "*errors.errorString"),
                    text("exception.message", "context deadline exceeded"),
                    text("exception.stacktrace", stack),
                ],
            }
        ]
    elif draw.random() < event_share:
        item["events"] = [
            {
                "timeUnixNano": str(begin + duration // 2),
                "name": "cache.miss",
                "attributes": [text("cache.key", f"{name}:{draw.randrange(10**9)}")],
            }
        ]
    return item


def export_of(draw, spans):
    """Each pod's spans, as the export's `resourceSpans`."""
    pods = max(1, min(pods_max, spans // pods_per_spans))
    resource_spans = []
    for pod in range(pods):
        share = spans // pods + (1 if pod < spans % pods else 0)
        items, trace, parent = [], "", ""
        for index in range(share):
            if index % spans_per_trace == 0:
                trace, parent = octets(draw, 16), ""
            begin = start_ns + draw.randrange(5_000_000_000)
            items.append(span(draw, index, trace, parent, begin))
            parent = items[-1]["spanId"]
        resource_spans.append(
            {
                "resource": resource(draw, pod),
                "scopeSpans": [
                    {
                        "scope": {
                            "name": "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp",
                            "version": "0.63.0",
                        },
                        "spans": items,
                    }
                ],
            }
        )
    return resource_spans


def write(buf, out, spans, resource_spans):
    """Writes the export in proto3 JSON, in protobuf's binary form, and as a gRPC message in gzip,
    and prints the spans, the message's octets, and the octets in gzip."""
    with open(out + ".json", "w") as file:
        json.dump({"resourceSpans": resource_spans}, file)
    subprocess.run(
        [
            buf,
            "convert",
            "examples/otlp/proto",
            "--type",
            "opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest",
            "--from",
            out + ".json#format=json",
            "--to",
            out + ".binpb#format=binpb",
        ],
        check=True,
    )
    encoded = pathlib.Path(out + ".binpb").read_bytes()
    # gzip at Go's default level, with no time in its header, so each run writes the same octets.
    compressed = gzip.compress(encoded, compresslevel=6, mtime=0)
    # gRPC over HTTP/2, "Requests": a Compressed-Flag of 1, the Message-Length in four octets,
    # big-endian, then the compressed message.
    with open(out, "wb") as file:
        file.write(b"\1" + len(compressed).to_bytes(4, "big") + compressed)
    print(f"{spans} {len(encoded)} {len(compressed)}")


def main():
    buf, spans, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    variant = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    # Python seeds a generator from a string by its SHA-512, the same on every host.
    draw = random.Random(spans if variant == 0 else f"{spans}-{variant}")
    write(buf, out, spans, export_of(draw, spans))


if __name__ == "__main__":
    main()
