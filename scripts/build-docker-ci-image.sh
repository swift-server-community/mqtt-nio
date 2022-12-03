#!/usr/bin/env bash

set -eux

# build docker file
docker build --platform linux/amd64 -t mqttnio-mosquitto -f scripts/Dockerfile.ci .
# tag it
docker tag mqttnio-mosquitto adamfowlerphoto/mqttnio-mosquitto
# push it to repository
docker push adamfowlerphoto/mqttnio-mosquitto

