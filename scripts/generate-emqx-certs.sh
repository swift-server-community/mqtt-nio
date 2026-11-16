#!/bin/bash

set -eu -o pipefail

HOME_DIR=$(dirname "$0")
FULL_HOME="$(pwd)"/"$HOME_DIR"
SERVER=soto.codes

# OpenSSL does not support creating usable TLS certificates with X25519 signing keys.
# For QUIC/TLS, certificates are generated with ECDSA P-256 and X25519 is used during key exchange.
function generateCA() {
    SUBJECT=$1
    openssl req \
        -nodes \
        -x509 \
        -sha256 \
        -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 \
        -subj "$SUBJECT" \
        -days 365 \
        -keyout ca.key \
        -out ca.pem
}

function generateServerCertificate() {
    SUBJECT=$1
    NAME=$2
    openssl req \
        -new \
        -nodes \
        -sha256 \
        -subj "$SUBJECT" \
        -extensions v3_req \
        -reqexts SAN \
        -config <(cat "$FULL_HOME"/openssl.cnf <(printf "[SAN]\nsubjectAltName=DNS:$SERVER,DNS:localhost,IP:127.0.0.1\n")) \
        -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$NAME".key \
        -out "$NAME".csr

    openssl x509 \
        -req \
        -sha256 \
        -in "$NAME".csr \
        -CA ca.pem \
        -CAkey ca.key \
        -CAcreateserial \
        -extfile <(cat "$FULL_HOME"/openssl.cnf <(printf "subjectAltName=DNS:$SERVER,DNS:localhost,IP:127.0.0.1\n")) \
        -extensions v3_req \
        -out "$NAME".pem \
        -days 365
}

cd "$HOME_DIR"/../EMQX
mkdir -p certs
cd certs

generateCA "/C=UK/ST=Edinburgh/L=Edinburgh/O=MQTTNIO/OU=CA/CN=${SERVER}"
generateServerCertificate "/C=UK/ST=Edinburgh/L=Edinburgh/O=MQTTNIO/OU=Server/CN=${SERVER}" server

# EMQX defaults expect these names for TLS materials.
cp -f ca.pem cacert.pem
cp -f server.key key.pem
cp -f server.pem cert.pem
