#!/bin/bash

# Run mosquitto MQTT broker with configuration needed for the test suite.
#
# If mosquitto is installed locally, it will be run. Otherwise, fall back to
# running a containerized version of mosquitto. The --container/-C option may be
# supplied to force running a containerized mosquitto.
#
# N.B. On MacOS, a native mosquitto executable must be run to connect to
# mosquitto using a unix domain socket.

set -eu -o pipefail

usage()
{
    echo "Usage: mosquitto.sh [--container|-C]"
    exit 2
}

run-installed-mosquitto()
{
    mosquitto -c mosquitto/config/mosquitto.conf
}

run-containerized-mosquitto()
{
    docker run \
        -p 1883:1883 \
        -p 1884:1884 \
        -p 8883:8883 \
        -p 8080:8080 \
        -p 8081:8081 \
        -v "$(pwd)"/mosquitto/config:/mosquitto/config \
        -v "$(pwd)"/mosquitto/certs:/mosquitto/certs \
        -v "$(pwd)"/mosquitto/socket:/mosquitto/socket \
        eclipse-mosquitto
}

USE_CONTAINER=0

if [[ $# -gt 1 ]]; then
    usage
elif [[ $# -eq 1 ]]; then
    case "$1" in
        -C|--container) USE_CONTAINER=1 ;;
        *) usage ;;
    esac
fi

cd "$(dirname "$(dirname "$0")")"

if [[ $USE_CONTAINER -eq 1 ]]; then
    if [ "$(uname)" != "Linux" ]; then
        echo "warning: unix domain socket connections will not work with a mosquitto container on $(uname)"
    fi
    run-containerized-mosquitto
elif command -v mosquitto >/dev/null; then
    run-installed-mosquitto
elif [ "$(uname)" = "Linux" ]; then
    echo "notice: mosquitto not installed; running eclipse-mosquitto container instead..."
    run-containerized-mosquitto
else
    echo "error: mosquitto must be installed"
    if [ "$(uname)" = "Darwin" ]; then
        echo "mosquitto can be installed on MacOS with: brew install mosquitto"
    fi
    exit 1
fi
