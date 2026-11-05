#!/bin/sh
# Runs the ELIZA socket server and calls it with buf curl, whose client is connect-go's, in each
# protocol, and with curl over h11 and h2. It requires each answer octet for octet: a gRPC
# success, whose status rides in HTTP trailers, is checked here and nowhere else (decision 11).
# It needs buf on the path, or BUF naming it, and curl.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
zig build
log="$(mktemp)"
trap 'kill "${server}" 2>/dev/null || true; rm -f "${log}"' EXIT
# Port 0: the kernel picks a free port, which the server prints, so two runs never collide.
zig-out/bin/eliza-server 0 >"${log}" 2>&1 &
server=$!
port=""
for _ in $(seq 1 50); do
    port="$(sed -n 's/^listening on port \([0-9]*\)$/\1/p' "${log}")"
    [ -n "${port}" ] && break
    sleep 0.1
done
[ -n "${port}" ] || { echo "the server printed no port" >&2; cat "${log}" >&2; exit 1; }
base="http://127.0.0.1:${port}/connectrpc.eliza.v1.ElizaService"
failures=0
expect() {
    name="$1"
    want="$2"
    got="$3"
    if [ "${got}" = "${want}" ]; then
        echo "ok: ${name}"
    else
        echo "FAIL: ${name}: got ${got}, wanted ${want}" >&2
        failures=$((failures + 1))
    fi
}
call() {
    "${buf}" curl --http2-prior-knowledge --schema examples/proto --protocol "$1" -d "$2" "${base}/$3" 2>&1 | tr -d ' \n'
}
introduced='{"sentence":"HiAda,IamEliza."}{"sentence":"Beforewebegin,Ada,tellmehowyoucamehere."}{"sentence":"Howareyoufeelingtoday,Ada?"}'
conversed='{"sentence":"Whydoyousay\"a\"?"}{"sentence":"Whydoyousay\"b\"?"}'
for protocol in connect grpc grpcweb; do
    expect "${protocol} Say" '{"sentence":"Yousaid\"hi\".Howdoesthatmakeyoufeel?"}' "$(call "${protocol}" '{"sentence":"hi"}' Say)"
    expect "${protocol} Introduce" "${introduced}" "$(call "${protocol}" '{"name":"Ada"}' Introduce)"
    expect "${protocol} Converse" "${conversed}" "$(call "${protocol}" '{"sentence":"a"} {"sentence":"b"}' Converse)"
    expect "${protocol} Say error" '{"code":"invalid_argument","message":"saysomething"}' "$(call "${protocol}" '{}' Say)"
done
expect "curl h11 POST" '{"sentence":"You said \"hi\". How does that make you feel?"}' \
    "$(curl -sS -m 5 --json '{"sentence":"hi"}' "${base}/Say")"
expect "curl h2 GET" '{"sentence":"You said \"hi\". How does that make you feel?"}' \
    "$(curl -sS -m 5 --http2-prior-knowledge "${base}/Say?connect=v1&encoding=json&message=%7B%22sentence%22%3A%22hi%22%7D")"
expect "curl error status" '400' \
    "$(curl -sS -m 5 -o /dev/null -w '%{http_code}' --json '{}' "${base}/Say")"
# A long answer to a client that accepts gzip goes out compressed.
long="$(printf 'a%.0s' $(seq 1 2000))"
expect "gzip answer" 'gzip' \
    "$(curl -sS -m 5 -H 'accept-encoding: gzip' --json "{\"sentence\":\"${long}\"}" -D - -o /dev/null "${base}/Say" |
        sed -n 's/^content-encoding: *\([a-z]*\).*$/\1/Ip' | tr -d '\r')"
# A unary request with two messages is refused with UNIMPLEMENTED, in gRPC-Web's trailers frame.
printf '\000\000\000\000\003\012\001a\000\000\000\000\003\012\001a' >"${log}.body"
expect "two messages for a unary call" '1' \
    "$(curl -sS -m 5 --http2-prior-knowledge -H 'content-type: application/grpc-web+proto' --data-binary "@${log}.body" "${base}/Say" |
        grep -ac 'grpc-status: 12')"
rm -f "${log}.body"
[ "${failures}" -eq 0 ] || exit 1
echo "every interop call answered as expected"
