"""Reads a message with Python's protobuf runtime, whose upb parser follows the editions features
for closed enums and unchecked strings (protobuf.dev, "Enum Behavior"), and compares what Zig
wrote with it. tools/coverage_check.sh runs it on each binary case.

    upb_reference.py binary <descriptors> <type> <case.binpb> <zig.binpb>
    upb_reference.py json <descriptors> <type> <case.binpb> <zig.json>

`binary` requires upb to write the same octets for both inputs: a number a closed enum does not
name sits with the unknown fields in each. `json` requires Zig's JSON to equal upb's.
"""

import json
import sys

from google.protobuf import descriptor_pb2, descriptor_pool, json_format, message_factory


def message_class(descriptors_path, type_name):
    with open(descriptors_path, "rb") as source:
        files = descriptor_pb2.FileDescriptorSet.FromString(source.read())
    pool = descriptor_pool.DescriptorPool()
    for file in files.file:
        pool.Add(file)
    return message_factory.GetMessageClass(pool.FindMessageTypeByName(type_name))


def read(cls, path):
    with open(path, "rb") as source:
        return cls.FromString(source.read())


def main(mode, descriptors_path, type_name, case_path, zig_path):
    cls = message_class(descriptors_path, type_name)
    want = read(cls, case_path)
    if mode == "binary":
        wanted = want.SerializeToString(deterministic=True)
        got = read(cls, zig_path).SerializeToString(deterministic=True)
    else:
        wanted = json_format.MessageToDict(want)
        with open(zig_path, encoding="utf-8") as source:
            got = json.load(source)
    if wanted == got:
        return 0
    print(f"upb read: {wanted!r}", file=sys.stderr)
    print(f"Zig wrote: {got!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
