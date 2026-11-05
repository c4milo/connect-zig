"""The grpcio interop client: calls interop.v1.InteropService over gRPC on h2 cleartext.

Usage: client.py <generated-dir> <base-url> <cases-dir>
It prints one line per scenario and exits 1 when any scenario fails (interop/README.md).
"""

import os
import queue
import sys
import urllib.parse

import grpc
from google.protobuf import any_pb2, descriptor_pb2, descriptor_pool, message_factory

CLIENT = "python"
PROTOCOL = "grpc"
CALL_TIMEOUT_SECONDS = 10
INSPECT_TIMEOUT_SECONDS = 5
# grpc-core encodes grpc-timeout from a cached clock and rounds it up to the next 10 ms, so a
# 5 s timeout goes out as "5010m" on every call after a channel's first, which interop/README.md
# allows.
GRPC_CORE_TIMEOUT_STEP_MS = 10
INSPECT_TIMEOUT_MAX_MS = INSPECT_TIMEOUT_SECONDS * 1000 + GRPC_CORE_TIMEOUT_STEP_MS
REPEAT_COUNT = 3
FAIL_CODE = grpc.StatusCode.NOT_FOUND
FAIL_MESSAGE = "gone"
HEADER_NAME = "x-interop-client"
STATUS_DETAILS_KEY = "grpc-status-details-bin"


class Failure(Exception):
    """A scenario saw something other than what the contract asks for."""


def same(left, right):
    """Compares two messages by the octets the runtime writes for them."""
    return left.SerializeToString(deterministic=True) == right.SerializeToString(deterministic=True)


def expect(condition, detail):
    if not condition:
        raise Failure(detail)


def status_class():
    """Builds google.rpc.Status from its descriptor, so the client needs no grpcio-status."""
    pool = descriptor_pool.Default()
    try:
        return message_factory.GetMessageClass(pool.FindMessageTypeByName("google.rpc.Status"))
    except KeyError:
        pass
    file = descriptor_pb2.FileDescriptorProto(
        name="interop_client/google_rpc_status.proto",
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


def run_echo(stub, case, **options):
    response = stub.Echo(case, timeout=CALL_TIMEOUT_SECONDS, **options)
    expect(same(case, response), "the echo differs from the request")


def run_repeat(stub, interop_pb2, cases):
    case = cases[0]
    request = interop_pb2.RepeatRequest(message=case, count=REPEAT_COUNT)
    responses = list(stub.Repeat(request, timeout=CALL_TIMEOUT_SECONDS))
    expect(len(responses) == REPEAT_COUNT, f"got {len(responses)} messages, want {REPEAT_COUNT}")
    for index, response in enumerate(responses):
        expect(same(case, response), f"message {index} differs from the request")


def run_collect(stub, interop_pb2, cases):
    response = stub.Collect(iter(cases), timeout=CALL_TIMEOUT_SECONDS)
    expect(response.count == len(cases), f"count {response.count}, want {len(cases)}")
    expect(same(response.last, cases[-1]), "last differs from the last case")


def run_chat(stub, interop_pb2, cases):
    # The request iterator yields the next case only after the response loop has received the
    # echo of the previous one, so the call passes only when the server answers full-duplex.
    answered = queue.Queue()
    stalled = []

    def requests():
        for index, case in enumerate(cases):
            yield case
            try:
                answered.get(timeout=CALL_TIMEOUT_SECONDS)
            except queue.Empty:
                stalled.append(index)
                return

    responses = []
    for response in stub.Chat(requests(), timeout=CALL_TIMEOUT_SECONDS * 2):
        responses.append(response)
        answered.put(True)
    expect(not stalled, f"no answer to case {stalled[0] if stalled else 0} before the next send")
    expect(len(responses) == len(cases), f"got {len(responses)} answers, want {len(cases)}")
    for index, (case, response) in enumerate(zip(cases, responses)):
        expect(same(case, response), f"answer {index} differs from its case")


def run_fail(stub, interop_pb2, cases):
    request = interop_pb2.FailRequest(code=FAIL_CODE.value[0], message=FAIL_MESSAGE)
    try:
        stub.Fail(request, timeout=CALL_TIMEOUT_SECONDS)
    except grpc.RpcError as error:
        expect(error.code() == FAIL_CODE, f"code {error.code()}, want {FAIL_CODE}")
        expect(error.details() == FAIL_MESSAGE, f"message {error.details()!r}")
        details = [value for key, value in error.trailing_metadata() or () if key == STATUS_DETAILS_KEY]
        expect(len(details) == 1, f"{len(details)} {STATUS_DETAILS_KEY} trailers, want 1")
        status = status_class().FromString(details[0])
        expect(status.code == request.code, f"status code {status.code}")
        expect(status.message == FAIL_MESSAGE, f"status message {status.message!r}")
        expect(len(status.details) == 1, f"{len(status.details)} details, want 1")
        detail = status.details[0]
        expect(detail.type_url.endswith("/interop.v1.FailRequest"), f"type {detail.type_url!r}")
        expect(same(interop_pb2.FailRequest.FromString(detail.value), request), "detail differs")
        return
    raise Failure("the call succeeded")


def run_inspect(stub, interop_pb2, cases):
    header = (HEADER_NAME, CLIENT)
    response, call = stub.Inspect.with_call(
        interop_pb2.InspectRequest(), timeout=INSPECT_TIMEOUT_SECONDS, metadata=[header]
    )
    timeout_ms = response.timeout_ms
    expect(1 <= timeout_ms <= INSPECT_TIMEOUT_MAX_MS, f"timeout {timeout_ms} ms")
    expect(f"{HEADER_NAME}: {CLIENT}" in response.headers, f"headers {list(response.headers)}")
    expect(header in tuple(call.initial_metadata()), "the header is not a response header")
    expect(header in tuple(call.trailing_metadata()), "the header is not a trailer")


def report(scenario, check, *arguments, **options):
    """Runs one scenario and prints its line; returns whether it passed."""
    try:
        check(*arguments, **options)
    except Failure as failure:
        print(f"FAIL: {CLIENT} {PROTOCOL} {scenario}: {failure}", flush=True)
        return False
    except grpc.RpcError as error:
        print(f"FAIL: {CLIENT} {PROTOCOL} {scenario}: {error.code()}: {error.details()}", flush=True)
        return False
    print(f"ok: {CLIENT} {PROTOCOL} {scenario}", flush=True)
    return True


def main():
    generated_dir, base_url, cases_dir = sys.argv[1:]
    sys.path.insert(0, generated_dir)
    from coverage.v1 import coverage_pb2
    from interop.v1 import interop_pb2, interop_pb2_grpc

    names = sorted(name for name in os.listdir(cases_dir) if name.endswith(".binpb"))
    cases = []
    for name in names:
        with open(os.path.join(cases_dir, name), "rb") as file:
            cases.append((name.removesuffix(".binpb"), coverage_pb2.Everything.FromString(file.read())))
    messages = [message for _, message in cases]

    target = urllib.parse.urlsplit(base_url).netloc
    results = []
    with grpc.insecure_channel(target) as channel:
        stub = interop_pb2_grpc.InteropServiceStub(channel)
        for name, message in cases:
            results.append(report(f"echo {name}", run_echo, stub, message))
        for name, message in cases:
            gzip = grpc.Compression.Gzip
            results.append(report(f"echo-gzip {name}", run_echo, stub, message, compression=gzip))
        for scenario, check in (
            ("repeat", run_repeat),
            ("collect", run_collect),
            ("chat", run_chat),
            ("fail", run_fail),
            ("inspect", run_inspect),
        ):
            results.append(report(scenario, check, stub, interop_pb2, messages))
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
