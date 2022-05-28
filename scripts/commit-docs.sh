#!/bin/bash

set -eux

# stash everything that isn't in docs, store result in STASH_RESULT
STASH_RESULT=$(git stash -- ":(exclude)docs")
# get branch name
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
REVISION_HASH=$(git rev-parse HEAD)

mv docs _docs
git checkout gh-pages
# copy contents of docs to docs/current replacing the ones that are already there
rm -rf current
mv _docs/mqtt-nio/current current
# commit
git add --all current

git status
git commit -m "Documentation for https://github.com/adam-fowler/mqtt-nio/tree/$REVISION_HASH"
git push
# return to branch
git checkout $CURRENT_BRANCH

if [ "$STASH_RESULT" != "No local changes to save" ]; then
    git stash pop
fi

