//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2025 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension Dictionary where Key == TopicFilter {
    /// Iterates through all the keys, which should be MQTT topic filters,
    /// checks which of them match with the provided topic name,
    /// and returns an array of the associated values.
    subscript(topicName topicName: String) -> [Value] {
        let nameLevels = topicName.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
        return self.filter { topicFilter, _ in
            let filterLevels = topicFilter.levels

            var nameIndex = 0
            var filterIndex = 0

            while filterIndex < filterLevels.count && nameIndex < nameLevels.count {
                let filterLevel = filterLevels[filterIndex]

                switch filterLevel {
                case .multiLevelWildcard:
                    // Multi-level wildcard matches any remaining levels
                    return true
                case .singleLevelWildcard:
                    // Single-level wildcard matches exactly one level
                    nameIndex += 1
                    filterIndex += 1
                case .string(let filterString) where filterString == nameLevels[nameIndex]:
                    // Exact match
                    nameIndex += 1
                    filterIndex += 1
                default:
                    // No match
                    return false
                }
            }

            // Handle remaining filter levels
            if filterIndex < filterLevels.count {
                // Only valid if remaining is just "#"
                return filterIndex == filterLevels.count - 1 && filterLevels[filterIndex] == .multiLevelWildcard
            }

            // Both must be fully consumed
            return nameIndex == nameLevels.count
        }.map { $0.value }
    }
}
