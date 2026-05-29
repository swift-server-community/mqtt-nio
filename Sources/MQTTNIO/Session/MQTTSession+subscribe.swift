//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

extension MQTTSession {
    /// Subscribe to a destination and keep the subscription active across connections using this ``MQTTSession``.
    ///
    /// The subscription will be sent to the broker immediately if the session is connected,
    /// otherwise it will be sent when the session connects.
    /// The subscription is automatically unsubscribed when the `process` closure returns or throws.
    ///
    /// - Parameters:
    ///   - subscriptions: Array of ``MQTTSubscribeInfoV5`` defining the subscriptions.
    ///   - subscribeProperties: Properties to attach to the subscribe packet.
    ///   - unsubscribeProperties: Properties to attach to the unsubscribe packet.
    ///   - process: Closure where messages received from the subscription are processed.
    ///     The closure receives a ``MQTTSubscription`` `AsyncSequence` to listen for messages.
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
