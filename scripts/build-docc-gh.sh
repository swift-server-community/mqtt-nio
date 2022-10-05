#!/usr/bin/env bash
# GitHub action version of build-docc which does not use the plugin. While GH actions
# are not available in the macOS-latest image GitHub provide this script will be necessary
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
docc convert Sources/MQTTNIO/MQTTNIO.docc \
    --transform-for-static-hosting \
    --hosting-base-path /mqtt-nio \
    --fallback-display-name MQTTNIO \
    --fallback-bundle-identifier org.swift-server-community.mqtt-nio \
    --fallback-bundle-version 1 \
    --additional-symbol-graph-dir $MQTTNIO_SG_FOLDER \
    --output-path $OUTPUT_PATH