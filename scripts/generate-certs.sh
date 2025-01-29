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
        -days 1825 \
        -keyout ca.key \
        -out ca.pem
    openssl x509 -in ca.pem -out ca.der -outform DER
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
        -CA ca.pem \
        -CAkey ca.key \
        -CAcreateserial \
        -extfile <(cat "$FULL_HOME"/openssl.cnf <(printf "subjectAltName=DNS:$SERVER\n")) \
        -extensions v3_req \
        -out "$NAME".pem \
        -days 1825
}

function generateClientCertificate() {
    SUBJECT=$1
    NAME=$2
    #PASSWORD=$(openssl rand -base64 29 | tr -d "=+/" | cut -c1-25)
    PASSWORD="MQTTNIOClientCertPassword"
    openssl req \
        -new \
        -nodes \
        -sha256 \
        -subj "$SUBJECT" \
        -keyout "$NAME".key \
        -out "$NAME".csr
        
    openssl x509 \
        -req \
        -sha256 \
        -in "$NAME".csr \
        -CA ca.pem \
        -CAkey ca.key \
        -CAcreateserial \
        -out "$NAME".pem \
        -days 1825

    openssl pkcs12 -export -passout pass:"$PASSWORD" -out "$NAME".p12 -in "$NAME".pem -inkey "$NAME".key
    
    echo "Password: $PASSWORD"
}

cd "$HOME"/../mosquitto/certs/

OUTPUT_ROOT=1
OUTPUT_CLIENT=1
OUTPUT_SERVER=1

while getopts 'sc' option
do
    case $option in
        s) OUTPUT_ROOT=0;OUTPUT_SERVER=1;OUTPUT_CLIENT=0 ;;
        c) OUTPUT_ROOT=0;OUTPUT_SERVER=0;OUTPUT_CLIENT=1 ;;
    esac
done

if test "$OUTPUT_ROOT" == 1; then
    generateCA "/C=UK/ST=Edinburgh/L=Edinburgh/O=MQTTNIO/OU=CA/CN=${SERVER}"
fi
if test "$OUTPUT_SERVER" == 1; then
    generateServerCertificate "/C=UK/ST=Edinburgh/L=Edinburgh/O=MQTTNIO/OU=Server/CN=${SERVER}" server
fi
if test "$OUTPUT_CLIENT" == 1; then
    generateClientCertificate "/C=UK/ST=Edinburgh/L=Edinburgh/O=MQTTNIO/OU=Client/CN=${SERVER}" client
fi
