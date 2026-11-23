#!/bin/sh
# The quickstart's own check, which `zig build test` runs: it starts the server on port 0 under
# the identity in <identity-dir> (chain.pem, key.pem and ca.pem), then calls it with the client,
# over h2 and h3, and with curl, in JSON over h11. All three run over TLS.
#
#   check.sh <greet-server> <greet-client> <identity-dir>
set -eu
server_binary="$1"
client_binary="$2"
identity="$3"
log="$(mktemp)"
server_pid=""
trap '[ -n "${server_pid}" ] && kill "${server_pid}" 2>/dev/null; rm -f "${log}"' EXIT
"${server_binary}" 0 "${identity}/chain.pem" "${identity}/key.pem" 2>"${log}" &
server_pid=$!
# The server's first line names its port. 100 tries of 0.1 s wait 10 s at most.
port=""
for _ in $(seq 1 100); do
    port="$(sed -n 's/^listening on port \([0-9][0-9]*\)$/\1/p' "${log}")"
    [ -n "${port}" ] && break
    sleep 0.1
done
if [ -z "${port}" ]; then
    cat "${log}" >&2
    echo "the server printed no port" >&2
    exit 1
fi
"${client_binary}" "${port}" "${identity}/ca.pem"
answer="$(curl -sS --http1.1 --cacert "${identity}/ca.pem" --json '{"name":"Ada"}' \
    "https://127.0.0.1:${port}/greet.v1.GreetService/Greet")"
if [ "${answer}" != '{"greeting":"Hello, Ada"}' ]; then
    echo "curl read ${answer}" >&2
    exit 1
fi
kill "${server_pid}"
wait "${server_pid}" 2>/dev/null || true
server_pid=""
echo "quickstart: the server answered its client over h2 and h3, and curl over h11"
