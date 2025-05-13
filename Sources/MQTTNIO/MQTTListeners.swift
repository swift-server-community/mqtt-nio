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

final class MQTTListeners<ReturnType> {
    typealias Listener = (ReturnType) -> Void

    func notify(_ result: ReturnType) {
        let listeners = self.lock.withLock {
            return self.listeners
        }
        for listener in listeners.values {
            listener(result)
        }
    }

    func addListener(named name: String, listener: @escaping Listener) {
        self.lock.withLock {
            self.listeners[name] = listener
        }
    }

    func removeListener(named name: String) {
        self.lock.withLock {
            self.listeners[name] = nil
        }
    }

    func removeAll() {
        self.lock.withLock {
            self.listeners = [:]
        }
    }

    private let lock = NIOLock()
    private var listeners: [String: Listener] = [:]
}
