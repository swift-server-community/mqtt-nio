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
        try await self.subscribe(
            to: subscriptions,
            subscribeProperties: subscribeProperties,
            unsubscribeProperties: unsubscribeProperties
        ) { subscription, _ in
            try await process(subscription)
        }
    }

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
    ///     The closure also receives an optional ``MQTTSubackV5`` containing the SUBACK packet details.
    ///     If it's `nil`, it means that no new subscription was opened with the server,
    ///     and instead a previously existing subscription with the same topic filters is being used.
    @inlinable
    public func subscribe<Value>(
        to subscriptions: [MQTTSubscribeInfoV5],
        subscribeProperties: MQTTProperties = .init(),
        unsubscribeProperties: MQTTProperties = .init(),
        process: (MQTTSubscription, MQTTSubackV5?) async throws -> Value
    ) async throws -> Value {
        let (id, subscribeStream, stream) = try self.subscribe(to: subscriptions, properties: subscribeProperties)
        let status = try await subscribeStream.first { _ in true }
        // don't defer unsubscribe until we are sure we have actually subscribed
        defer { self.subscriptionsQueueContinuation.yield(.unsubscribe(.init(id: id, properties: unsubscribeProperties))) }
        // if stream returns nil task must have been cancelled
        guard status != nil else { throw CancellationError() }
        return try await process(stream, status?.subAckPacket.map { .init(reasons: $0.reasons, properties: $0.properties) })
    }

    @usableFromInline
    func subscribe(
        to subscriptions: [MQTTSubscribeInfoV5],
        properties: MQTTProperties = .init()
    ) throws -> (UInt32, AsyncThrowingStream<SubscriptionStatus, any Error>, MQTTSubscription) {
        let (subscribeStream, subscribeContinuation) = AsyncThrowingStream.makeStream(of: SubscriptionStatus.self)
        let (stream, streamContinuation) = MQTTSubscription.makeStream()
        if Task.isCancelled {
            throw MQTTError.cancelled
        }
        let subscriptionID = MQTTSubscriptions.getSubscriptionID()
        let subscription = QueuedSubscription(
            id: subscriptionID,
            subscribeContinuation: subscribeContinuation,
            continuation: streamContinuation,
            subscriptions: subscriptions,
            properties: properties
        )
        subscriptionsQueueContinuation.yield(.subscribe(subscription))
        return (subscriptionID, subscribeStream, stream)
    }
}
