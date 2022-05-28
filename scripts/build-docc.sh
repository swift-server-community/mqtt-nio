#!/usr/bin/env bash

DOCC=$(xcrun --find docc)
export DOCC_HTML_DIR="$(dirname $DOCC)/../share/docc/render"
SG_FOLDER=.build/symbol-graphs
MQTTNIO_SG_FOLDER=.build/mqtt-nio-symbol-graphs
OUTPUT_PATH=docs/mqtt-nio

BUILD_SYMBOLS=1

while getopts 's' option
do
    case $option in
        s) BUILD_SYMBOLS=0;;
    esac
done

if test "$BUILD_SYMBOLS" == 1; then
    # build symbol graphs
    mkdir -p $SG_FOLDER
    swift build \
        -Xswiftc -emit-symbol-graph \
        -Xswiftc -emit-symbol-graph-dir -Xswiftc $SG_FOLDER
    # Copy MQTTNIO symbol graph into separate folder
    mkdir -p $MQTTNIO_SG_FOLDER
    cp -f $SG_FOLDER/MQTTNIO* $MQTTNIO_SG_FOLDER
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
