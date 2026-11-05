#!/bin/sh
# Mints the test-only TLS identity of the examples' h3 rounds into examples/testdata/tls/: a P-256
# CA, and a leaf for localhost and 127.0.0.1 that the CA signs (decision 25). Both are valid from
# 2020-01-01 to 2099-12-31, so the examples' fixed instant, 1_800_000_000, falls inside. The
# profile is the one colibri's own test identity has, which chapulin's Web PKI mode accepts.
# It runs `openssl ca`, whose -startdate and -enddate OpenSSL 3.0 already reads. Each run mints new
# keys, so the committed files change. The private keys are for tests alone.
set -eu
cd "$(dirname "$0")/.."
openssl="${OPENSSL:-openssl}"
output="examples/testdata/tls"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

cat > "${scratch}/ca.cnf" <<'EOF'
[ca]
default_ca = test_ca

[test_ca]
database = index.txt
serial = serial
new_certs_dir = .
default_md = sha256
policy = policy_any
unique_subject = no
email_in_dn = no

[policy_any]
commonName = supplied

[ca_extensions]
keyUsage = critical,digitalSignature,keyCertSign
basicConstraints = critical,CA:TRUE
subjectKeyIdentifier = hash

[leaf_extensions]
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
basicConstraints = critical,CA:FALSE
authorityKeyIdentifier = keyid
subjectKeyIdentifier = none
subjectAltName = DNS:localhost,IP:127.0.0.1
EOF

(
    cd "${scratch}"
    : > index.txt
    echo 01 > serial
    # notBefore is a UTCTime and notAfter a GeneralizedTime: chapulin reads a year before 2050 only
    # as a UTCTime, and a year from 2050 on only as a GeneralizedTime (RFC 5280 §4.1.2.5).
    validity="-startdate 200101000000Z -enddate 20991231235959Z"
    "${openssl}" ecparam -name prime256v1 -genkey -noout -out ca.key
    "${openssl}" req -new -key ca.key -subj "/CN=connect-zig test CA" -config ca.cnf -out ca.csr
    # shellcheck disable=SC2086
    "${openssl}" ca -batch -notext -config ca.cnf -selfsign -keyfile ca.key -in ca.csr \
        ${validity} -extensions ca_extensions -out ca.pem
    "${openssl}" ecparam -name prime256v1 -genkey -noout -out leaf.ec
    "${openssl}" pkcs8 -topk8 -nocrypt -in leaf.ec -out key.pem
    "${openssl}" req -new -key key.pem -subj "/CN=localhost" -config ca.cnf -out leaf.csr
    # shellcheck disable=SC2086
    "${openssl}" ca -batch -notext -config ca.cnf -cert ca.pem -keyfile ca.key -in leaf.csr \
        ${validity} -extensions leaf_extensions -out leaf.pem
    "${openssl}" verify -CAfile ca.pem leaf.pem
    cat leaf.pem ca.pem > chain.pem
)
mkdir -p "${output}"
cp "${scratch}/ca.pem" "${scratch}/chain.pem" "${scratch}/key.pem" "${output}/"
echo "wrote ${output}/ca.pem, chain.pem and key.pem"
