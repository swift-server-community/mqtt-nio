//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2021 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

enum MQTTPromise<T: Sendable>: Sendable {
    case nio(EventLoopPromise<T>)
    case swift(CheckedContinuation<T, any Error>)
    case forget

    func succeed(_ t: T) {
        switch self {
        case .nio(let eventLoopPromise):
            eventLoopPromise.succeed(t)
        case .swift(let checkedContinuation):
            checkedContinuation.resume(returning: t)
        case .forget:
            break
        }
    }

    func fail(_ e: Error) {
        switch self {
        case .nio(let eventLoopPromise):
            eventLoopPromise.fail(e)
        case .swift(let checkedContinuation):
            checkedContinuation.resume(throwing: e)
        case .forget:
            break
        }
    }
}

/// Class encapsulating a single task
final class MQTTTask {
    let promise: MQTTPromise<MQTTPacket>
    let checkInbound: (MQTTPacket) throws -> Bool
    let requestID: Int
    let timeoutTask: Scheduled<Void>?

    init(
        promise: MQTTPromise<MQTTPacket>,
        requestID: Int,
        on eventLoop: EventLoop,
        timeout: TimeAmount?,
        checkInbound: @escaping (MQTTPacket) throws -> Bool
    ) {
        self.promise = promise
        self.checkInbound = checkInbound
        self.requestID = requestID
        if let timeout {
            self.timeoutTask = eventLoop.scheduleTask(in: timeout) {
                promise.fail(MQTTError.timeout)
            }
        } else {
            self.timeoutTask = nil
        }
    }

    func succeed(_ response: MQTTPacket) {
        self.timeoutTask?.cancel()
        self.promise.succeed(response)
    }

    func fail(_ error: Error) {
        self.timeoutTask?.cancel()
        self.promise.fail(error)
    }
}
