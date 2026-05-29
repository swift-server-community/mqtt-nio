//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

struct TopicFilter: Hashable, Sendable {
    enum Level: Equatable {
        case string(Substring)
        case multiLevelWildcard
        case singleLevelWildcard
    }

    let levels: [Level]

    init(_ topicFilter: String) throws {
        self.string = topicFilter
        let filterLevels = topicFilter.split(separator: "/", omittingEmptySubsequences: false)
        self.levels = try filterLevels.enumerated().map { index, level in
            switch level {
            case "#":
                // Multi-level wildcard must be the last level
                guard index == filterLevels.count - 1 else {
                    throw MQTTError.invalidTopicFilter(topicFilter)
                }
                return .multiLevelWildcard
            case "+":
                return .singleLevelWildcard
            default:
                return .string(level)
            }
        }
    }

    let string: String

    static func == (lhs: TopicFilter, rhs: TopicFilter) -> Bool {
        lhs.string == rhs.string
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(string)
    }
}
