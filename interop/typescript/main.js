// The connect-es interop client: it calls interop.v1.InteropService on connect-zig's socket server
// in each protocol connect-es speaks, and prints one line per scenario (interop/README.md).
//
// Usage: node main.js <base-url> <cases-dir> <ca>
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { createRegistry, fromBinary, fromJsonString, toBinary, toJsonString } from "@bufbuild/protobuf";
import {
  file_google_protobuf_any,
  file_google_protobuf_duration,
  file_google_protobuf_empty,
  file_google_protobuf_field_mask,
  file_google_protobuf_struct,
  file_google_protobuf_timestamp,
  file_google_protobuf_wrappers,
} from "@bufbuild/protobuf/wkt";
import { Code, ConnectError, createClient } from "@connectrpc/connect";
import {
  compressionGzip,
  createConnectTransport,
  createGrpcTransport,
  createGrpcWebTransport,
  Http2SessionManager,
} from "@connectrpc/connect-node";
import { Agent } from "node:https";
import { EverythingSchema, file_coverage_v1_coverage } from "./gen/coverage/v1/coverage_pb.js";
import {
  FailRequestSchema,
  InteropService,
  file_interop_v1_interop,
} from "./gen/interop/v1/interop_pb.js";

const clientName = "typescript";
// Each call fails after this long, so a server that never answers fails a scenario, not the run.
const callTimeoutMs = 10_000;
const inspectTimeoutMs = 5_000;
const repeatCount = 3;
const failCode = 5;

const [baseUrl, casesDir, caPath] = process.argv.slice(2);
if (!baseUrl || !casesDir || !caPath) {
  console.error("usage: node main.js <base-url> <cases-dir> <ca>");
  process.exit(2);
}
// The server's TLS identity is the test one: both transports trust its CA, and the server picks
// h2 or h11 by ALPN.
const ca = readFileSync(caPath);

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

// Each case is a coverage.v1.Everything, read once and kept with the octets connect-es writes for
// it. JSON cannot carry a NaN's payload, and connect-es writes -0 as 0, so over JSON the expected
// octets are those of the case after connect-es's own JSON round trip.
const cases = readdirSync(casesDir)
  .filter((name) => name.endsWith(".binpb"))
  .sort()
  .map((file) => {
    const message = fromBinary(EverythingSchema, readFileSync(join(casesDir, file)));
    const viaJson = fromJsonString(EverythingSchema, toJsonString(EverythingSchema, message, { registry }), { registry });
    return {
      name: file.slice(0, -".binpb".length),
      message,
      binary: toBinary(EverythingSchema, message),
      json: toBinary(EverythingSchema, viaJson),
    };
  });

let failures = 0;
// The codec of the protocol under test: "binary" or "json".
let codec = "binary";

async function scenario(protocol, name, body) {
  try {
    await body();
    console.log(`ok: ${clientName} ${protocol} ${name}`);
  } catch (error) {
    failures += 1;
    const detail = error instanceof Error ? error.message : String(error);
    console.log(`FAIL: ${clientName} ${protocol} ${name}: ${detail.replace(/\s+/g, " ")}`);
  }
}

function expect(condition, detail) {
  if (!condition) throw new Error(detail);
}

// expectSame throws unless the message writes the same octets as the case.
function expectSame(testCase, message, what = "the response") {
  const want = Buffer.from(testCase[codec]);
  const got = Buffer.from(toBinary(EverythingSchema, message));
  expect(want.equals(got), `${what} differs from ${testCase.name}: want ${want.toString("hex")}, got ${got.toString("hex")}`);
}

async function echoScenarios(protocol, client, prefix, call) {
  for (const testCase of cases) {
    await scenario(protocol, `${prefix} ${testCase.name}`, async () => {
      expectSame(testCase, await call(client, testCase.message, { timeoutMs: callTimeoutMs }));
    });
  }
}

async function repeat(client) {
  const testCase = cases[0];
  const responses = [];
  const stream = client.repeat({ message: testCase.message, count: repeatCount }, { timeoutMs: callTimeoutMs });
  for await (const response of stream) responses.push(response);
  expect(responses.length === repeatCount, `want ${repeatCount} messages, got ${responses.length}`);
  responses.forEach((response, index) => expectSame(testCase, response, `message ${index}`));
}

async function collect(client) {
  async function* requests() {
    for (const testCase of cases) yield testCase.message;
  }
  const response = await client.collect(requests(), { timeoutMs: callTimeoutMs });
  expect(response.count === cases.length, `want count ${cases.length}, got ${response.count}`);
  expect(response.last !== undefined, "the response has no last message");
  expectSame(cases[cases.length - 1], response.last, "last");
}

// chat sends a case only after the server answered the one before, so it passes only when the
// server answers while the request stream is still open.
async function chat(client) {
  let received = 0;
  let wake = () => {};
  async function* requests() {
    for (const [sent, testCase] of cases.entries()) {
      while (received < sent) await new Promise((resolve) => (wake = resolve));
      yield testCase.message;
    }
    while (received < cases.length) await new Promise((resolve) => (wake = resolve));
  }
  for await (const response of client.chat(requests(), { timeoutMs: callTimeoutMs })) {
    expect(received < cases.length, `got more than ${cases.length} messages`);
    expectSame(cases[received], response, `answer ${received}`);
    received += 1;
    wake();
  }
  expect(received === cases.length, `want ${cases.length} answers, got ${received}`);
}

async function fail(client) {
  let error;
  try {
    await client.fail({ code: failCode, message: "gone" }, { timeoutMs: callTimeoutMs });
  } catch (caught) {
    error = ConnectError.from(caught);
  }
  expect(error !== undefined, "the call succeeded");
  expect(error.code === Code.NotFound, `want code not_found, got ${Code[error.code]}`);
  expect(error.rawMessage === "gone", `want message "gone", got ${JSON.stringify(error.rawMessage)}`);
  expect(error.details.length === 1, `want 1 detail, got ${error.details.length}`);
  const details = error.findDetails(FailRequestSchema);
  expect(details.length === 1, "the detail is not an interop.v1.FailRequest");
  const detail = details[0];
  expect(
    detail.code === failCode && detail.message === "gone",
    `the detail holds code ${detail.code} and message ${JSON.stringify(detail.message)}`,
  );
}

async function inspect(client) {
  const header = "x-interop-client";
  let responseHeader = null;
  let responseTrailer = null;
  const response = await client.inspect(
    {},
    {
      timeoutMs: inspectTimeoutMs,
      headers: { [header]: clientName },
      onHeader: (headers) => (responseHeader = headers.get(header)),
      onTrailer: (trailers) => (responseTrailer = trailers.get(header)),
    },
  );
  const timeoutMs = Number(response.timeoutMs);
  expect(timeoutMs >= 1 && timeoutMs <= inspectTimeoutMs, `the server saw a timeout of ${timeoutMs} ms`);
  const want = `${header}: ${clientName}`;
  expect(response.headers.includes(want), `the server saw headers ${JSON.stringify(response.headers)}`);
  expect(responseHeader === clientName, `the response header is ${JSON.stringify(responseHeader)}`);
  expect(responseTrailer === clientName, `the response trailer is ${JSON.stringify(responseTrailer)}`);
}

// Each protocol makes its transports from options. connect-h1 runs only the echoes, over
// HTTP/1.1; the others run every scenario over h2.
const protocols = [
  { name: "connect-proto", make: createConnectTransport, options: {}, get: true, everything: true },
  { name: "connect-json", make: createConnectTransport, options: { useBinaryFormat: false, jsonOptions: { registry } }, get: true, everything: true },
  { name: "connect-h1", make: createConnectTransport, options: { httpVersion: "1.1" }, get: true, everything: false },
  { name: "grpc", make: createGrpcTransport, options: {}, get: false, everything: true },
  { name: "grpc-web", make: createGrpcWebTransport, options: {}, get: false, everything: true },
];

for (const protocol of protocols) {
  codec = protocol.options.useBinaryFormat === false ? "json" : "binary";
  // All of a protocol's transports share one connection, closed when the protocol is done: the
  // server serves a few sockets at a time.
  const agent = new Agent({ keepAlive: true, maxSockets: 1, ca, ALPNProtocols: ["http/1.1"] });
  const sessionManager = new Http2SessionManager(baseUrl, undefined, { ca });
  const connection = protocol.options.httpVersion === "1.1" ? { nodeOptions: { agent } } : { httpVersion: "2", sessionManager };
  const clientWith = (options) =>
    createClient(InteropService, protocol.make({ baseUrl, ...connection, ...protocol.options, ...options }));
  const client = clientWith({});
  const gzipClient = clientWith({ sendCompression: compressionGzip, compressMinBytes: 0 });
  await echoScenarios(protocol.name, client, "echo", (c, m, o) => c.echo(m, o));
  await echoScenarios(protocol.name, gzipClient, "echo-gzip", (c, m, o) => c.echo(m, o));
  if (protocol.get) {
    await echoScenarios(protocol.name, clientWith({ useHttpGet: true }), "echo-get", (c, m, o) => c.echoGet(m, o));
  }
  if (protocol.everything) {
    await scenario(protocol.name, "repeat", () => repeat(client));
    await scenario(protocol.name, "collect", () => collect(client));
    await scenario(protocol.name, "chat", () => chat(client));
    await scenario(protocol.name, "fail", () => fail(client));
    await scenario(protocol.name, "inspect", () => inspect(client));
  }
  sessionManager.abort();
  agent.destroy();
}

process.exit(failures === 0 ? 0 : 1);
