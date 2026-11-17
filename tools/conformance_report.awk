# Writes one half's conformance cases as a Markdown table, from the log of connectrpc's runner run
# with -v (tools/conformance_check.sh). Each "Running N tests with <peer> for server config
# {<version>, <protocol>, TLS:<tls>}" line gives a row's cases. Each "FAILED: <case>" line counts
# a failure, and each "INFO: <case> failed (as expected)" line a known failing or flaky case that
# failed. A case's name carries its HTTP version and TLS, and its protocol but in a few suites,
# whose own name gives it. The peer is connectrpc's reference implementation, on connect-go, or
# its grpc-go one, which the runner marks "(grpc)" or "grpc-reference-", and a case's name
# "(grpc ... impl)".

# The table's key of the configuration a failed case ran in.
function key_of(line,    name, version, protocol, tls, peer) {
    name = line
    sub(/^(FAILED|INFO): /, "", name)
    version = name
    if (!sub(/.*HTTPVersion:/, "", version)) return "unmapped"
    sub(/[^0-9].*/, "", version)
    tls = name
    if (!sub(/.*\/TLS:/, "", tls)) return "unmapped"
    sub(/[^a-z].*/, "", tls)
    protocol = name
    if (sub(/.*Protocol:/, "", protocol)) {
        sub(/[^A-Z_].*/, "", protocol)
    } else if (name ~ /^gRPC-Web /) {
        protocol = "PROTOCOL_GRPC_WEB"
    } else if (name ~ /^gRPC /) {
        protocol = "PROTOCOL_GRPC"
    } else {
        protocol = "PROTOCOL_CONNECT"
    }
    peer = name ~ /\(grpc (client|server) impl\)/ ? "grpc-go" : "connect-go"
    return "HTTP_VERSION_" version "|" protocol "|TLS:" tls "|" peer
}

# The key of a "Running" line's configuration and peer.
function key_of_running(line,    config, peer) {
    # Runner v1.0.4 writes "reference client (grpc)", and v1.0.7 "grpc-reference-client".
    peer = line ~ /(\(grpc\)|grpc-reference-(client|server)) for server config/ ? "grpc-go" : "connect-go"
    config = line
    sub(/.*\{/, "", config)
    sub(/\}.*/, "", config)
    gsub(/, /, "|", config)
    return config "|" peer
}

# A key that sorts by HTTP version, then protocol in the order Connect, gRPC, gRPC-Web, then
# cleartext before TLS, then connect-go before grpc-go.
function order_of(key,    part, rank) {
    if (key == "unmapped") return "~"
    split(key, part, "|")
    rank = part[2] == "PROTOCOL_CONNECT" ? 1 : part[2] == "PROTOCOL_GRPC" ? 2 : 3
    return part[1] rank (part[3] == "TLS:true" ? 1 : 0) (part[4] == "grpc-go" ? 1 : 0)
}

function row_of(key,    part, version, protocol) {
    if (key == "unmapped") return "| none in the case's name | | |"
    split(key, part, "|")
    version = part[1]
    sub(/HTTP_VERSION_/, "", version)
    if (version == "1") version = "1.1"
    protocol = part[2] == "PROTOCOL_CONNECT" ? "Connect" : part[2] == "PROTOCOL_GRPC" ? "gRPC" : "gRPC-Web"
    return "| " version " | " protocol " | " (part[3] == "TLS:true" ? "yes" : "no") " | " part[4]
}

/^Running [0-9]+ tests .*server config .*\{/ {
    key = key_of_running($0)
    if (!(key in cases)) keys[++count] = key
    cases[key] += $2
    total += $2
}
/^FAILED: / { failed[key_of($0)]++ }
/^INFO: .* failed \(as expected\)/ { expected[key_of($0)]++ }
/^Total cases: [0-9]+$/ { runner_total = $3 }

END {
    if (count == 0) {
        print "The runner's log names no configuration, so this half has no table."
        exit
    }
    # A failure in a configuration no "Running" line named still gets a row, so no failure is lost.
    for (key in failed) if (!(key in cases)) { cases[key] = 0; keys[++count] = key }
    for (key in expected) if (!(key in cases)) { cases[key] = 0; keys[++count] = key }
    # The runner starts configurations in parallel, so their lines arrive in any order.
    for (i = 2; i <= count; i++) {
        for (j = i; j > 1 && order_of(keys[j - 1]) > order_of(keys[j]); j--) {
            swap = keys[j]
            keys[j] = keys[j - 1]
            keys[j - 1] = swap
        }
    }
    print "| HTTP | Protocol | TLS | Reference peer | Cases | Failed | Failed as expected |"
    print "| --- | --- | --- | --- | ---: | ---: | ---: |"
    for (i = 1; i <= count; i++) {
        key = keys[i]
        printf "%s | %d | %d | %d |\n", row_of(key), cases[key], failed[key], expected[key]
        all_failed += failed[key]
        all_expected += expected[key]
    }
    printf "| All | | | | %d | %d | %d |\n", total, all_failed, all_expected
    if (runner_total != "" && runner_total != total) {
        printf "\nThe rows sum to %d cases, and the runner counted %d.\n", total, runner_total
    }
}
