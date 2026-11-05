#!/bin/sh
# Runs the example socket server and calls it with buf curl, whose client is connect-go's, in each
# protocol, and with curl over h11 and h2. It requires each answer octet for octet: a gRPC
# success, whose status rides in HTTP trailers, is checked here and nowhere else (decision 11).
# It needs buf on the path, or BUF naming it, and curl.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
# Each call gets this many seconds, so a server that sends a broken reply fails the check and
# never hangs it.
call_seconds=10
zig build
log="$(mktemp)"
trap 'kill "${server}" 2>/dev/null || true; rm -f "${log}" "${log}.body" "${log}.fifo" "${log}.chat"' EXIT
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
    timeout "${call_seconds}" "${buf}" curl --http2-prior-knowledge --schema examples/proto --protocol "$1" -d "$2" "${base}/$3" 2>&1 | tr -d ' \n'
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

# The demo service: interceptors, every kind of stream, and error details.
base="http://127.0.0.1:${port}/demo.v1.DemoService"
demo() {
    demo_protocol="$1"
    shift
    timeout "${call_seconds}" "${buf}" curl --http2-prior-knowledge --schema examples/proto --protocol "${demo_protocol}" "$@" 2>&1 | tr -d ' \n'
}
for protocol in connect grpc grpcweb; do
    expect "${protocol} Whoami with a token" '{"name":"Ada"}' \
        "$(demo "${protocol}" -H 'authorization: Bearer Ada' "${base}/Whoami" | sed 's/,"callsBefore":"[0-9]*"//')"
    expect "${protocol} Whoami without a token" '{"code":"unauthenticated","message":"abearertokenisrequired"}' \
        "$(demo "${protocol}" "${base}/Whoami")"
    expect "${protocol} Sum" '{"sum":"7","count":"2"}' "$(demo "${protocol}" -d '{"number":3} {"number":4}' "${base}/Sum")"
    expect "${protocol} Countdown" '{"number":2}{"number":1}' "$(demo "${protocol}" -d '{"from":2}' "${base}/Countdown")"
    expect "${protocol} Divide error" \
        '{"code":"invalid_argument","message":"divisionbyzero","details":[{"type":"demo.v1.DivisionByZero","value":"CAc"}]}' \
        "$(demo "${protocol}" -d '{"dividend":7}' "${base}/Divide")"
done
# A gRPC error before any message is Trailers-Only: one header section holds the status and the
# call's own trailers, here Counting's.
expect "grpc Trailers-Only carries trailers" 'call-received: 1|call-sent: 0|' \
    "$(timeout "${call_seconds}" "${buf}" curl --http2-prior-knowledge --schema examples/proto --protocol grpc -v \
        -d '{"dividend":7}' "${base}/Divide" 2>&1 | sed -n 's/^buf: < (#1) //p' | tr -d '\r' |
        grep -i -e '^call-received:' -e '^call-sent:' | tr 'A-Z' 'a-z' | tr '\n' '|')"
# Logging's response header, and Whoami's trailer, which a Connect unary reply sends as a header.
expect "Connect unary headers" 'demo-logged: yes|trailer-whoami-caller: Ada|' \
    "$(curl -sS -m 5 -m 5 -H 'authorization: Bearer Ada' --json '{}' -D - -o /dev/null "${base}/Whoami" |
        tr -d '\r' | grep -i -e '^demo-logged:' -e '^trailer-whoami-caller:' | tr '\n' '|')"
# Full duplex: Chat's answer to the first message must arrive while the client still holds its
# stream open, before it sends the second.
fifo="${log}.fifo"
mkfifo "${fifo}"
timeout "${call_seconds}" "${buf}" curl --http2-prior-knowledge --schema examples/proto --protocol grpc -d @- "${base}/Chat" <"${fifo}" >"${log}.chat" 2>&1 &
chat=$!
exec 3>"${fifo}"
echo '{"text":"first"}' >&3
answered=no
for _ in $(seq 1 50); do
    grep -q 'echo: first' "${log}.chat" && { answered=yes; break; }
    sleep 0.1
done
echo '{"text":"second"}' >&3
exec 3>&-
wait "${chat}" || true
expect "grpc Chat answers before the client ends" 'yes' "${answered}"
expect "grpc Chat" '{"text":"echo:first"}{"text":"echo:second"}{"text":"byeafter2"}' "$(tr -d ' \n' <"${log}.chat")"
rm -f "${fifo}" "${log}.chat"
[ "${failures}" -eq 0 ] || exit 1
echo "every interop call answered as expected"
