//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

extension MQTTConnection {
    /// Subscribe to a destination.
    ///
    /// The subscription is automatically unsubscribed when the `process` closure returns or throws.
    ///
    /// - Parameters:
    ///   - subscriptions: Array of ``MQTTSubscribeInfo`` defining the subscriptions.
    ///   - process: Closure where messages received from the subscription are processed.
    ///     The closure receives a ``MQTTSubscription`` `AsyncSequence` to listen for messages.
    @inlinable
    public nonisolated func subscribe<Value>(
        to subscriptions: [MQTTSubscribeInfo],
        process: (MQTTSubscription) async throws -> Value
    ) async throws -> Value {
        try await self.subscribe(to: subscriptions) { subscription, _ in
            try await process(subscription)
        }
    }

    /// Subscribe to a destination.
    ///
    /// The subscription is automatically unsubscribed when the `process` closure returns or throws.
    ///
    /// - Parameters:
    ///   - subscriptions: Array of ``MQTTSubscribeInfo`` defining the subscriptions.
    ///   - process: Closure where messages received from the subscription are processed.
    ///     The closure receives a ``MQTTSubscription`` `AsyncSequence` to listen for messages.
    ///     The closure also receives an optional ``MQTTSuback`` containing the SUBACK packet details.
    ///     If it's `nil`, it means that no new subscription was opened with the server,
    ///     and instead a previously existing subscription with the same topic filters is being used.
    @inlinable
    public nonisolated func subscribe<Value>(
        to subscriptions: [MQTTSubscribeInfo],
        process: (MQTTSubscription, MQTTSuback?) async throws -> Value
    ) async throws -> Value {
        let (id, subAckPacket, stream) = try await self.subscribe(to: subscriptions.map { .init(topicFilter: $0.topicFilter, qos: $0.qos) })
        let value: Value
        do {
            value = try await process(stream, subAckPacket.map { .init(returnCodes: $0.reasons.compactMap { .init(rawValue: $0.rawValue) }) })
            try Task.checkCancellation()
        } catch {
            // call unsubscribe in unstructured Task to avoid it being cancelled
            _ = await Task {
                try await self.unsubscribe(id: id)
            }.result
            throw error
        }
        // call unsubscribe in unstructured Task to avoid it being cancelled
        _ = try await Task {
            try await self.unsubscribe(id: id)
        }.value
        return value
    }

    @usableFromInline
    func subscribe(
        to subscriptions: [MQTTSubscribeInfoV5],
        properties: MQTTProperties = .init()
    ) async throws -> (UInt32, MQTTSubAckPacket?, MQTTSubscription) {
        let (stream, streamContinuation) = MQTTSubscription.makeStream()
        if Task.isCancelled {
            throw MQTTError.cancelled
        }
        let packet = MQTTSubscribePacket(subscriptions: subscriptions, properties: properties, packetId: self.updatePacketId())
        let (subscriptionID, subAckPacket): (UInt32, MQTTSubAckPacket?) = try await withCheckedThrowingContinuation { continuation in
            self.channelHandler.subscribe(
                streamContinuation: streamContinuation,
                packet: packet,
                promise: .swift(continuation),
                requestID: Self.requestIDGenerator.next()
            )
        }
        return (subscriptionID, subAckPacket, stream)
    }

    @usableFromInline
    func unsubscribe(id: UInt32, properties: MQTTProperties = .init()) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.channelHandler.unsubscribe(
                id: id,
                packetID: self.updatePacketId(),
                properties: properties,
                promise: .swift(continuation),
                requestID: Self.requestIDGenerator.next()
            )
        }
    }
}

extension MQTTConnection.V5 {
    /// Subscribe to a destination.
    ///
    /// The subscription is automatically unsubscribed when the `process` closure returns or throws.
    ///
    /// - Parameters:
    ///   - subscriptions: Array of ``MQTTSubscribeInfoV5`` defining the subscriptions.
    ///   - subscribeProperties: Properties to attach to the subscribe packet.
    ///   - unsubscribeProperties: Properties to attach to the unsubscribe packet.
    ///   - process: Closure where messages received from the subscription are processed.
    ///     The closure receives a ``MQTTSubscription`` `AsyncSequence` to listen for messages.
    @inlinable
    public nonisolated func subscribe<Value>(
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

    /// Subscribe to a destination.
    ///
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
    public nonisolated func subscribe<Value>(
        to subscriptions: [MQTTSubscribeInfoV5],
        subscribeProperties: MQTTProperties = .init(),
        unsubscribeProperties: MQTTProperties = .init(),
        process: (MQTTSubscription, MQTTSubackV5?) async throws -> Value
    ) async throws -> Value {
        let (id, subAckPacket, stream) = try await self.connection.subscribe(to: subscriptions, properties: subscribeProperties)
        let value: Value
        do {
            value = try await process(stream, subAckPacket.map { .init(reasons: $0.reasons, properties: $0.properties) })
            try Task.checkCancellation()
        } catch {
            // call unsubscribe in unstructured Task to avoid it being cancelled
            _ = await Task {
                try await self.connection.unsubscribe(id: id, properties: unsubscribeProperties)
            }.result
            throw error
        }
        // call unsubscribe in unstructured Task to avoid it being cancelled
        _ = try await Task {
            try await self.connection.unsubscribe(id: id, properties: unsubscribeProperties)
        }.value
        return value
    }
}
