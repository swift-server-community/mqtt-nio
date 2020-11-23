#!/bin/bash

set -eux

HOME=$(dirname "$0")

function generateCA() {
    SUBJECT=$1
    openssl req -x509 -nodes -sha256 -newkey rsa:2048 -subj "$SUBJECT"  -days 365 -keyout ca.key -out ca.crt
}

function generateCertificate() {
    SUBJECT=$1
    NAME=$2
    openssl req -new -nodes -sha256 -subj "$SUBJECT" -keyout "$NAME".key -out "$NAME".csr
    openssl x509 -req -sha256 -in "$NAME".csr -CA ca.crt -CAkey ca.key -CAcreateserial -out "$NAME".crt -days 365
}

cd "$HOME"/../mosquitto/certs/

generateCA "/C=UK/ST=Edinburgh/L=Edinburgh/O=Soto/OU=MQTTCA/CN=root"
generateCertificate "/C=UK/ST=Edinburgh/L=Edinburgh/O=Soto/OU=MQTTServer/CN=soto.codes" server
generateCertificate "/C=UK/ST=Edinburgh/L=Edinburgh/O=Soto/OU=MQTTClient/CN=soto-project.codes" client
