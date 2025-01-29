#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

SWIFT_FORMAT_VERSION=0.52.10

set -eu

command -v swiftformat >/dev/null || {
  echo "swiftformat not installed. You can install it using 'mint install nicklockwood/swiftformat'"
  exit 1
}

printf "=> Checking format... "
FIRST_OUT="$(git status --porcelain)"
git ls-files -z '*.swift' | xargs -0 swift format format --parallel --in-place
git diff --exit-code '*.swift'

SECOND_OUT="$(git status --porcelain)"
if [[ "$FIRST_OUT" != "$SECOND_OUT" ]]; then
  printf "\033[0;31mformatting issues!\033[0m\n"
  git --no-pager diff
  exit 1
else
  printf "\033[0;32mokay.\033[0m\n"
fi
