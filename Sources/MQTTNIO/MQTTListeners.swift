//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2022 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOConcurrencyHelpers

struct MQTTListeners<ReturnType> {
    typealias Listener = (Result<ReturnType, Error>) -> Void

    func notify(_ result: Result<ReturnType, Error>) {
        self.lock.withLock {
            listeners.values.forEach { listener in
                listener(result)
            }
        }
    }

    mutating func addListener(named name: String, listener: @escaping Listener) {
        self.lock.withLock {
            listeners[name] = listener
        }
    }

    mutating func removeListener(named name: String) {
        self.lock.withLock {
            listeners[name] = nil
        }
    }

    private let lock = NIOLock()
    private var listeners: [String: Listener] = [:]
}
