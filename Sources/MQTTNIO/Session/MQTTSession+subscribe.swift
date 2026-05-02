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

extension MQTTSession {
    @inlinable
    public func subscribe<Value>(
        to subscriptions: [MQTTSubscribeInfoV5],
        subscribeProperties: MQTTProperties = .init(),
        unsubscribeProperties: MQTTProperties = .init(),
        process: (MQTTSubscription) async throws -> Value
    ) async throws -> Value {
        let (id, stream) = try self.subscribe(to: subscriptions, properties: subscribeProperties)
        defer { self.subscriptionsQueueContinuation.yield(.unsubscribe(.init(id: id, properties: unsubscribeProperties))) }
        return try await process(stream)
    }

    @usableFromInline
    func subscribe(
        to subscriptions: [MQTTSubscribeInfoV5],
        properties: MQTTProperties = .init()
    ) throws -> (UInt32, MQTTSubscription) {
        let (stream, streamContinuation) = MQTTSubscription.makeStream()
        if Task.isCancelled {
            throw MQTTError.cancelledTask
        }
        let subscriptionID = MQTTSubscriptions.getSubscriptionID()
        let subscription = QueuedSubscription(
            id: subscriptionID,
            continuation: streamContinuation,
            subscriptions: subscriptions,
            properties: properties
        )
        subscriptionsQueueContinuation.yield(.subscribe(subscription))
        return (subscriptionID, stream)
    }
}
