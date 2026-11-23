"""The fields of each message type of tools/cel_differential/generate.py, and the values its
rules and its messages draw from."""

FIELDS = """  string s = 1;
  string t = 2;
  int32 i = 3;
  int64 j = 4;
  uint32 u = 5;
  uint64 v = 6;
  double d = 7;
  bool b = 8;
  bytes y = 9;
  repeated string rs = 10;
  repeated int32 ri = 11;
  map<string, int32> msi = 12;
  google.protobuf.Duration dur = 13;
  Leaf leaf = 14;
"""

STRINGS = [
    "",
    "a",
    "b",
    "ab",
    "x1",
    "foo@example.com",
    "example.com",
    "1.2.3.4",
    "::1",
    "héllo",
    "https://a.example/b",
    "10",
    "-7",
    "true",
    "k",
]
# RE2 patterns that Go's regexp and stdx's regex both read, and that match texts of STRINGS in
# different ways: anchors, classes, ASCII's case folding, repetition, alternation and `.` over
# a character of two octets.
PATTERNS = [
    "^a",
    "b$",
    "^[a-z]+$",
    "(?i)^A",
    "\\d+",
    "^\\w+@\\w+\\.com$",
    "x|1",
    "^(ab)*$",
    "[^a-z]",
    "^.{2,5}$",
    "é",
    "^$",
    "\\.",
    "^[0-9a-f:.]+$",
    "^-?[0-9]+$",
]
INTS = [0, 1, -1, 2, 3, 7, 10, 100, -100, 2**31 - 1, -(2**31)]
LONGS = INTS + [2**62, -(2**62), 2**63 - 1, -(2**63)]
UINTS = [0, 1, 2, 5, 100, 2**32 - 1]
ULONGS = UINTS + [2**63, 2**64 - 1]
DOUBLES = ["0.0", "1.5", "2.0", "-2.25", "100.0", "1e300"]
DURATIONS = ["0s", "1s", "5s", "90s", "1h", "-3s", "1.5s"]
# Timestamps in UTC: cel-go writes a timestamp read with an offset in that offset, where this
# library writes UTC (docs/specs/README.md), so `string` of one would differ on purpose.
TIMESTAMPS = [
    "2023-12-25T12:30:45.678Z",
    "2000-02-29T23:59:59Z",
    "1970-01-01T00:00:00Z",
    "0001-01-01T00:00:00Z",
    "9999-12-31T23:59:59.999999999Z",
    "2024-03-01T08:00:00Z",
]
# Zones cel-go and this library both read: UTC and fixed offsets, no names.
ZONES = ["UTC", "+05:30", "-08:00", "-00:30", "+14:00", "-12:45", "5:00", "+23:59"]
TIMESTAMP_PARTS = [
    "getFullYear",
    "getMonth",
    "getDate",
    "getDayOfMonth",
    "getDayOfYear",
    "getDayOfWeek",
    "getHours",
    "getMinutes",
    "getSeconds",
    "getMilliseconds",
]
DURATION_PARTS = ["getHours", "getMinutes", "getSeconds", "getMilliseconds"]
# The names of types an expression may write: CEL's own, a message's, and two well-known types'.
TYPE_NAMES = [
    "int",
    "uint",
    "double",
    "string",
    "bytes",
    "bool",
    "list",
    "map",
    "null_type",
    "type",
    "diff.v1.Leaf",
    "google.protobuf.Duration",
    "google.protobuf.Timestamp",
]
# The texts of STRINGS that are identifiers, so a map's key may be selected as a field: `m.ab`.
KEYS = ["a", "b", "ab", "x1", "k"]
