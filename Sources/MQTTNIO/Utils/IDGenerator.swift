//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2026 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Synchronization

@usableFromInline
struct IDGenerator: ~Copyable, Sendable {
    private let atomic: Atomic<Int>

    public init() {
        self.atomic = .init(0)
    }

    @usableFromInline
    func next() -> Int {
        self.atomic.wrappingAdd(1, ordering: .relaxed).newValue
    }
}
