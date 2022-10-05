#!/usr/bin/env bash

# if plugin worked for us then would use it over everything below
usePlugin()
{
    mkdir -p ./docs/mqtt-nio
    swift package \
        --allow-writing-to-directory ./docs \
        generate-documentation \
        --target MQTTNIO \
        --output-path ./docs/mqtt-nio \
        --transform-for-static-hosting \
        --hosting-base-path /mqtt-nio
}

usePlugin
