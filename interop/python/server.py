"""The grpcio interop server: interop.v1.InteropService over gRPC, h2 and TLS with the test identity.

connect-zig's interop client calls it (interop/README.md, "The server side"). It answers as
connect-zig's own server of examples/services/interop.zig does.

Usage: python server.py <generated-dir> <port> <chain> <key>
Port 0 lets the kernel choose. The server prints "listening on port <port>" once it listens.
"""

import sys
from concurrent import futures

import grpc
from google.protobuf import any_pb2, descriptor_pb2, descriptor_pool, message_factory

# The most messages Repeat sends, as examples/services/interop.zig allows.
REPEAT_MAX = 16
# The prefix of the request headers Inspect reports and sends back.
INSPECTED_PREFIX = "x-interop-"
# statuscodes.md: the codes a failure may carry are 1 to 16.
CODE_MIN = 1
CODE_MAX = 16
# PROTOCOL-HTTP2.md does not name it, but every gRPC library reads a google.rpc.Status here.
STATUS_DETAILS_KEY = "grpc-status-details-bin"
# The calls the server runs at once: Chat holds a worker for its whole stream.
WORKERS = 16
MILLISECONDS_PER_SECOND = 1000


def status_class():
    """Builds google.rpc.Status from its descriptor, so the server needs no grpcio-status."""
    pool = descriptor_pool.Default()
    file = descriptor_pb2.FileDescriptorProto(
        name="interop_server/google_rpc_status.proto",
        package="google.rpc",
        syntax="proto3",
        dependency=[any_pb2.DESCRIPTOR.name],
    )
    message = file.message_type.add(name="Status")
    field = descriptor_pb2.FieldDescriptorProto
    message.field.add(name="code", number=1, type=field.TYPE_INT32, label=field.LABEL_OPTIONAL)
    message.field.add(name="message", number=2, type=field.TYPE_STRING, label=field.LABEL_OPTIONAL)
    message.field.add(
        name="details",
        number=3,
        type=field.TYPE_MESSAGE,
        label=field.LABEL_REPEATED,
        type_name=".google.protobuf.Any",
    )
    pool.Add(file)
    return message_factory.GetMessageClass(pool.FindMessageTypeByName("google.rpc.Status"))


def make_servicer(interop_pb2, interop_pb2_grpc, coverage_pb2):
    status = status_class()

    class Servicer(interop_pb2_grpc.InteropServiceServicer):
        def Echo(self, request, context):
            return request

        def EchoGet(self, request, context):
            return request

        def Repeat(self, request, context):
            if request.count < 0 or request.count > REPEAT_MAX:
                context.abort(grpc.StatusCode.OUT_OF_RANGE, "count must be between 0 and 16")
            message = request.message if request.HasField("message") else coverage_pb2.Everything()
            for _ in range(request.count):
                yield message

        def Collect(self, request_iterator, context):
            response = interop_pb2.CollectResponse()
            for request in request_iterator:
                response.count += 1
                response.last.CopyFrom(request)
            return response

        def Chat(self, request_iterator, context):
            # grpcio hands each message over as it arrives, so each answer goes before the next.
            for request in request_iterator:
                yield request

        def Fail(self, request, context):
            if request.code < CODE_MIN or request.code > CODE_MAX:
                context.abort(grpc.StatusCode.INVALID_ARGUMENT, "code must be between 1 and 16")
            code = next(each for each in grpc.StatusCode if each.value[0] == request.code)
            detail = any_pb2.Any()
            detail.Pack(request)
            details = status(code=request.code, message=request.message, details=[detail])
            context.set_trailing_metadata(((STATUS_DETAILS_KEY, details.SerializeToString()),))
            context.abort(code, request.message)

        def Inspect(self, request, context):
            seen = [
                (key, value)
                for key, value in context.invocation_metadata()
                if key.startswith(INSPECTED_PREFIX)
            ]
            context.send_initial_metadata(seen)
            context.set_trailing_metadata(seen)
            remaining = context.time_remaining()
            timeout_ms = 0 if remaining is None else int(remaining * MILLISECONDS_PER_SECOND)
            return interop_pb2.InspectResponse(
                timeout_ms=timeout_ms, headers=[f"{key}: {value}" for key, value in seen]
            )

    return Servicer()


def main():
    generated_dir, port, chain_path, key_path = sys.argv[1:]
    sys.path.insert(0, generated_dir)
    from coverage.v1 import coverage_pb2
    from interop.v1 import interop_pb2, interop_pb2_grpc

    with open(chain_path, "rb") as file:
        chain = file.read()
    with open(key_path, "rb") as file:
        key = file.read()
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=WORKERS))
    servicer = make_servicer(interop_pb2, interop_pb2_grpc, coverage_pb2)
    interop_pb2_grpc.add_InteropServiceServicer_to_server(servicer, server)
    bound = server.add_secure_port(f"127.0.0.1:{port}", grpc.ssl_server_credentials(((key, chain),)))
    server.start()
    print(f"listening on port {bound}", flush=True)
    server.wait_for_termination()


if __name__ == "__main__":
    main()
