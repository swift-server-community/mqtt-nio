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

extension MQTTConnection {
    /// Subscribe to a destination.
    ///
    /// The subscription is automatically unsubscribed when the `process` closure returns or throws.
    ///
    /// - Parameters:
    ///   - subscriptions: Array of ``MQTTSubscribeInfo`` defining the subscriptions.
    ///   - isolation: Actor isolation
    ///   - process: Closure where messages received from the subscription are processed.
    ///     The closure receives a ``MQTTSubscription`` `AsyncSequence` to listen for messages.
    public func subscribe<Value>(
        to subscriptions: [MQTTSubscribeInfo],
        isolation: isolated (any Actor)? = #isolation,
        process: (MQTTSubscription) async throws -> sending Value
    ) async throws -> sending Value {
        let (id, stream) = try await self.subscribe(to: subscriptions.map { .init(topicFilter: $0.topicFilter, qos: $0.qos) })
        let value: Value
        do {
            value = try await process(stream)
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

    func subscribe(
        to subscriptions: [MQTTSubscribeInfoV5],
        properties: MQTTProperties = .init()
    ) async throws -> (Int, MQTTSubscription) {
        let (stream, streamContinuation) = MQTTSubscription.makeStream()
        if Task.isCancelled {
            throw MQTTError.cancelledTask
        }
        let packet = MQTTSubscribePacket(subscriptions: subscriptions, properties: properties, packetId: self.updatePacketId())
        let subscriptionID: Int = try await withCheckedThrowingContinuation { continuation in
            self.channelHandler.subscribe(
                streamContinuation: streamContinuation,
                packet: packet,
                promise: .swift(continuation)
            )
        }
        return (subscriptionID, stream)
    }

    func unsubscribe(id: Int, properties: MQTTProperties = .init()) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.channelHandler.unsubscribe(id: id, packetID: self.updatePacketId(), properties: properties, promise: .swift(continuation))
        }
    }
}

extension MQTTConnection.V5 {
    /// Subscribe to a destination.
    ///
    /// The subscription is automatically unsubscribed when the `process` closure returns or throws.
    ///
    /// - Parameters:
    ///   - subscriptions: Array of ``MQTTSubscribeInfo`` defining the subscriptions.
    ///   - subscribeProperties: Properties to attach to the subscribe packet.
    ///   - unsubscribeProperties: Properties to attach to the unsubscribe packet.
    ///   - isolation: Actor isolation
    ///   - process: Closure where messages received from the subscription are processed.
    ///     The closure receives a ``MQTTSubscription`` `AsyncSequence` to listen for messages.
    public func subscribe<Value>(
        to subscriptions: [MQTTSubscribeInfoV5],
        subscribeProperties: MQTTProperties = .init(),
        unsubscribeProperties: MQTTProperties = .init(),
        isolation: isolated (any Actor)? = #isolation,
        process: (MQTTSubscription) async throws -> sending Value
    ) async throws -> sending Value {
        let (id, stream) = try await self.connection.subscribe(to: subscriptions, properties: subscribeProperties)
        let value: Value
        do {
            value = try await process(stream)
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
