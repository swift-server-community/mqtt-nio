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

enum UniqueReferenceError: Error {
    case alreadyBorrowed
}

struct UniqueReference<Value: Sendable>: ~Copyable, Sendable {
    let ref: Mutex<Value?>

    init(_ value: Value) {
        self.ref = .init(value)
    }

    /// borrow value and return a mutated version
    func mutatingBorrow<Return>(_ operation: (Value) async -> (Value, Result<Return, any Error>)) async throws -> Return {
        guard let value = take() else { throw UniqueReferenceError.alreadyBorrowed }
        let (newValue, result) = await operation(value)
        put(newValue)
        return try result.get()
    }

    /// borrow value without mutating it
    func borrow<Return>(_ operation: (Value) throws -> Return) throws -> Return {
        guard let value = take() else { throw UniqueReferenceError.alreadyBorrowed }
        do {
            let result = try operation(value)
            put(value)
            return result
        } catch {
            put(value)
            throw error
        }
    }

    private func take() -> Value? {
        self.ref.withLock {
            let value = $0
            $0 = nil
            return value
        }
    }

    private func put(_ value: Value) {
        self.ref.withLock {
            guard $0 == nil else { preconditionFailure("Value already stored") }
            $0 = value
        }
    }
}
