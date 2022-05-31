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

TEMP_DIR="$(pwd)/temp"

cleanup()
{
    if [ -n "$TEMP_DIR" ]; then
        rm -rf $TEMP_DIR
    fi
}
trap cleanup exit $?

SG_FOLDER=.build/symbol-graphs
MQTTNIO_SG_FOLDER=.build/mqtt-nio-symbol-graphs
OUTPUT_PATH=docs/mqtt-nio/

BUILD_SYMBOLS=1

while getopts 's' option
do
    case $option in
        s) BUILD_SYMBOLS=0;;
    esac
done

if [ -z "${DOCC_HTML_DIR:-}" ]; then
    git clone https://github.com/apple/swift-docc-render-artifact $TEMP_DIR/swift-docc-render-artifact
     export DOCC_HTML_DIR="$TEMP_DIR/swift-docc-render-artifact/dist"
fi

if test "$BUILD_SYMBOLS" == 1; then
    # build symbol graphs
    mkdir -p $SG_FOLDER
    swift build \
        -Xswiftc -emit-symbol-graph \
        -Xswiftc -emit-symbol-graph-dir -Xswiftc $SG_FOLDER
    # Copy MQTTNIO symbol graph into separate folder
    mkdir -p $MQTTNIO_SG_FOLDER
    cp $SG_FOLDER/MQTTNIO* $MQTTNIO_SG_FOLDER
fi

# Build documentation
mkdir -p $OUTPUT_PATH
rm -rf $OUTPUT_PATH/*
docc convert MQTTNIO.docc \
    --transform-for-static-hosting \
    --hosting-base-path /mqtt-nio \
    --fallback-display-name MQTTNIO \
    --fallback-bundle-identifier org.swift-server-community.mqtt-nio \
    --fallback-bundle-version 1 \
    --additional-symbol-graph-dir $MQTTNIO_SG_FOLDER \
    --output-path $OUTPUT_PATH
