#!/bin/bash

set -eux

HOME=$(dirname "$0")
FULL_HOME="$(pwd)"/"$HOME"
SERVER=localhost

function generateCA() {
    SUBJECT=$1
    openssl req \
        -nodes \
        -x509 \
        -sha256 \
        -newkey rsa:2048 \
        -subj "$SUBJECT" \
        -days 365 \
        -keyout ca.key \
        -out ca.crt
}

function generateCertificate() {
    SUBJECT=$1
    NAME=$2
    openssl req \
        -new \
        -nodes \
        -sha256 \
        -subj "$SUBJECT" \
        -extensions v3_req \
        -reqexts SAN \
        -config <(cat "$FULL_HOME"/openssl.cnf <(printf "[SAN]\nsubjectAltName=DNS:$SERVER\n")) \
        -keyout "$NAME".key \
        -out "$NAME".csr
        
    openssl x509 \
        -req \
        -sha256 \
        -in "$NAME".csr \
        -CA ca.crt \
        -CAkey ca.key \
        -CAcreateserial \
        -extfile <(cat "$FULL_HOME"/openssl.cnf <(printf "subjectAltName=DNS:$SERVER\n")) \
        -extensions v3_req \
        -out "$NAME".crt \
        -days 365
}

cd "$HOME"/../mosquitto/certs/

generateCA "/C=UK/ST=Edinburgh/L=Edinburgh/O=Soto/OU=MQTTCA/CN=${SERVER}"
generateCertificate "/C=UK/ST=Edinburgh/L=Edinburgh/O=Soto/OU=MQTTServer/CN=${SERVER}" server
generateCertificate "/C=UK/ST=Edinburgh/L=Edinburgh/O=Soto/OU=MQTTClient/CN=soto-project.codes" client
