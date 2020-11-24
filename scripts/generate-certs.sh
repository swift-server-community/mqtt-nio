#!/bin/bash

set -eu

HOME=$(dirname "$0")
FULL_HOME="$(pwd)"/"$HOME"
SERVER=soto.codes

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

function generateClientCertificate() {
    SUBJECT=$1
    NAME=$2
    PASSWORD=$(openssl rand -base64 29 | tr -d "=+/" | cut -c1-25)
    openssl req \
        -new \
        -nodes \
        -sha256 \
        -subj "$SUBJECT" \
        -keyout "$NAME".key \
        -out "$NAME".csr \
#        -passout pass:"$PASSWORD"
        
    openssl x509 \
        -req \
        -sha256 \
        -in "$NAME".csr \
        -CA ca.crt \
        -CAkey ca.key \
        -CAcreateserial \
        -out "$NAME".crt \
        -days 365 \
#        -passin pass:"$PASSWORD"

    openssl pkcs12 -export -passout pass:"$PASSWORD" -out "$NAME".p12 -in "$NAME".crt -inkey "$NAME".key
    
    echo "Password: $PASSWORD"
}

cd "$HOME"/../mosquitto/certs/

ROOT=1
CLIENT=1
SERVER=1

while getopts 'sc' option
do
    case $option in
        s) ROOT=0;SERVER=1;CLIENT=0 ;;
        c) ROOT=0;SERVER=0;CLIENT=1 ;;
    esac
done

if test "$ROOT" == 1; then
    generateCA "/C=UK/ST=Edinburgh/L=Edinburgh/O=Soto/OU=MQTTCA/CN=${SERVER}"
fi
if test "$SERVER" == 1; then
    generateServerCertificate "/C=UK/ST=Edinburgh/L=Edinburgh/O=Soto/OU=MQTTServer/CN=${SERVER}" server
fi
if test "$CLIENT" == 1; then
    generateClientCertificate "/C=UK/ST=Edinburgh/L=Edinburgh/O=Soto/OU=MQTTClient/CN=soto-project.codes" client
fi
