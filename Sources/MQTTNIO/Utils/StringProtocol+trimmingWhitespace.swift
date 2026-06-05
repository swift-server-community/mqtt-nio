//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

extension StringProtocol {
    func trimmingWhitespace() -> Self.SubSequence {
        self.trimmingWhitespacePrefix().trimmingWhitespaceSuffix()
    }

    func endOfWhitespacePrefix() -> Self.Index {
        var index = self.startIndex
        while index < self.endIndex, self[index].isWhitespace {
            formIndex(after: &index)
        }
        return index
    }

    func trimmingWhitespacePrefix() -> Self.SubSequence {
        let start = self.endOfWhitespacePrefix()
        return self[start..<self.endIndex]
    }

    func startOfWhitespaceSuffix() -> Self.Index {
        var index = self.endIndex
        while index > self.startIndex {
            let after = index
            formIndex(before: &index)
            if !self[index].isWhitespace {
                return after
            }
        }
        return index
    }

    func trimmingWhitespaceSuffix() -> Self.SubSequence {
        let end = self.startOfWhitespaceSuffix()
        return self[self.startIndex..<end]
    }
}
