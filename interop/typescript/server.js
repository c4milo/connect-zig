// The connect-node interop server: connect-es's router on Node's http2 server, serving Connect,
// gRPC and gRPC-Web over TLS with the test identity, h2 and HTTP/1.1 picked by ALPN.
// connect-zig's interop client calls it (interop/README.md, "The server side"). It answers as
// connect-zig's own server of examples/services/interop.zig does.
//
// Usage: node server.js <port> <chain> <key>
// Port 0 lets the kernel choose. The server prints "listening on port <port>" once it listens.
import { readFileSync } from "node:fs";
import { createSecureServer } from "node:http2";
import { createRegistry } from "@bufbuild/protobuf";
import {
  file_google_protobuf_any,
  file_google_protobuf_duration,
  file_google_protobuf_empty,
  file_google_protobuf_field_mask,
  file_google_protobuf_struct,
  file_google_protobuf_timestamp,
  file_google_protobuf_wrappers,
} from "@bufbuild/protobuf/wkt";
import { Code, ConnectError } from "@connectrpc/connect";
import { connectNodeAdapter } from "@connectrpc/connect-node";
import { file_coverage_v1_coverage } from "./gen/coverage/v1/coverage_pb.js";
import { FailRequestSchema, InteropService, file_interop_v1_interop } from "./gen/interop/v1/interop_pb.js";

// The most messages Repeat sends, as examples/services/interop.zig allows.
const repeatMax = 16;
// The prefix of the request headers Inspect reports and sends back.
const inspectedPrefix = "x-interop-";
// statuscodes.md: the codes a failure may carry are 1 to 16.
const codeMin = 1;
const codeMax = 16;

const [port, chainPath, keyPath] = process.argv.slice(2);
if (port === undefined || !chainPath || !keyPath) {
  console.error("usage: node server.js <port> <chain> <key>");
  process.exit(2);
}

// The JSON codec needs every type an Any in the cases can hold.
const registry = createRegistry(
  file_coverage_v1_coverage,
  file_interop_v1_interop,
  file_google_protobuf_any,
  file_google_protobuf_duration,
  file_google_protobuf_empty,
  file_google_protobuf_field_mask,
  file_google_protobuf_struct,
  file_google_protobuf_timestamp,
  file_google_protobuf_wrappers,
);

const service = {
  echo: (request) => request,
  echoGet: (request) => request,
  async *repeat(request) {
    if (request.count < 0 || request.count > repeatMax) {
      throw new ConnectError("count must be between 0 and 16", Code.OutOfRange);
    }
    for (let index = 0; index < request.count; index += 1) yield request.message ?? {};
  },
  async collect(requests) {
    let count = 0;
    let last;
    for await (const request of requests) {
      count += 1;
      last = request;
    }
    return { count, last };
  },
  async *chat(requests) {
    for await (const request of requests) yield request;
  },
  fail(request) {
    if (request.code < codeMin || request.code > codeMax) {
      throw new ConnectError("code must be between 1 and 16", Code.InvalidArgument);
    }
    throw new ConnectError(request.message, request.code, undefined, [{ desc: FailRequestSchema, value: request }]);
  },
  inspect(_request, context) {
    const headers = [];
    context.requestHeader.forEach((value, name) => {
      if (!name.startsWith(inspectedPrefix)) return;
      headers.push(`${name}: ${value}`);
      context.responseHeader.set(name, value);
      context.responseTrailer.set(name, value);
    });
    const timeoutMs = context.timeoutMs();
    return { timeoutMs: BigInt(timeoutMs === undefined ? 0 : Math.max(Math.floor(timeoutMs), 0)), headers };
  },
};

const handler = connectNodeAdapter({
  routes: (router) => router.service(InteropService, service),
  jsonOptions: { registry },
});
const server = createSecureServer(
  { cert: readFileSync(chainPath), key: readFileSync(keyPath), allowHTTP1: true },
  handler,
);
server.listen(Number(port), "127.0.0.1", () => {
  console.log(`listening on port ${server.address().port}`);
});
