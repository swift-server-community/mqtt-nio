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

SWIFT_VERSION=5.3

set -eu
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

which swiftformat > /dev/null 2>&1 || (echo "swiftformat not installed. You can install it using 'mint install nicklockwood/swiftformat'" ; exit -1)

printf "=> Checking format... "
FIRST_OUT="$(git status --porcelain)"
if [[ -n "${CI-""}" ]]; then
  printf "(using v$(mint run NickLockwood/SwiftFormat@0.48.17 --version)) "
  mint run NickLockwood/SwiftFormat@0.48.17 . > /dev/null 2>&1
else
  printf "(using v$(swiftformat --version)) "
  swiftformat . > /dev/null 2>&1
fi
SECOND_OUT="$(git status --porcelain)"
if [[ "$FIRST_OUT" != "$SECOND_OUT" ]]; then
  printf "\033[0;31mformatting issues!\033[0m\n"
  git --no-pager diff
  exit 1
else
  printf "\033[0;32mokay.\033[0m\n"
fi

