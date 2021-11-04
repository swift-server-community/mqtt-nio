#!/bin/bash

CONTAINER_ID=$(docker container ls | grep eclipse-mosquitto | awk {'print $1'})
COMMAND=$1
HOME=$(dirname $0)

usage()
{
    echo "Usage: mosquitto.sh [start] [stop] [status]"
    exit 2
}

run()
{
    if [ -z "$CONTAINER_ID" ]; then
        docker run \
            -p 1883:1883 \
            -p 1884:1884 \
            -p 8883:8883 \
            -p 8080:8080 \
            -p 8081:8081 \
            -v $(pwd)/$HOME/../mosquitto/config:/mosquitto/config \
            -v $(pwd)/$HOME/../mosquitto/certs:/mosquitto/certs \
            eclipse-mosquitto
    else
        echo "Mosquitto is already running"
    fi
}

start()
{
    if [ -z "$CONTAINER_ID" ]; then
        docker run \
            -d \
            -p 1883:1883 \
            -p 1884:1884 \
            -p 8883:8883 \
            -p 8080:8080 \
            -p 8081:8081 \
            -v $(pwd)/$HOME/../mosquitto/config:/mosquitto/config \
            -v $(pwd)/$HOME/../mosquitto/certs:/mosquitto/certs \
            eclipse-mosquitto
    else
        echo "Mosquitto is already running"
    fi
}

stop()
{
    if [ -n "$CONTAINER_ID" ]; then
        echo "Stopping mosquitto"
        docker container stop "$CONTAINER_ID"
        docker rm "$CONTAINER_ID"
    else
        echo "Mosquitto is already stopped"
    fi
}

status()
{
    if [ -n "$CONTAINER_ID" ]; then
        echo "Mosquitto is running"
    else
        echo "Mosquitto is not running"
    fi
}

if [ "$COMMAND" == "start" ]; then
    start
elif [ "$COMMAND" == "stop" ]; then
    stop
elif [ "$COMMAND" == "status" ]; then
    status
elif [ -z "$COMMAND" ]; then
    run
else
    usage
    exit -1
fi

