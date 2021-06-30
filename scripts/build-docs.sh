#!/usr/bin/env bash

set -eux

PROJECT=${1:-}
CWD=$(pwd)
TEMP_DIR=$(mktemp -d)

get_latest_version() {
    RELEASE_REVISION=$(git rev-list --tags --max-count=1)
    echo $(git describe --tags "$RELEASE_REVISION")
}

build_docs() {
    VERSION=$(get_latest_version)
    jazzy \
        --clean \
        --author "Adam Fowler" \
        --author_url https://github.com/adam-fowler \
        --github_url https://github.com/adam-fowler/mqtt-nio \
        --module-version "$VERSION" \
        --output "$CWD"/docs/
}

build_docs
