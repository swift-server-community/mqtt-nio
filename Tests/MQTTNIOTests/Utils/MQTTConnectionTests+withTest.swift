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

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import Testing

@testable import MQTTNIO

extension MQTTConnectionTests {
    /// Helper function to test an ``MQTTConnection`` with a test MQTT server using `NIOAsyncTestingChannel`.
    ///
    /// This function sets up a test MQTT server and establishes a connection using the provided configuration and session.
    /// It then performs the specified client and server operations concurrently, allowing for testing of various MQTT interactions.
    ///
    /// - Parameters:
    ///   - configuration: The configuration to use for the MQTT connection.
    ///   - session: The MQTT session to use for the connection.
    ///   - logger: The logger to use for logging MQTT events.
    ///   - connackProperties: The properties to include in the CONNACK packet.
    ///   - clientOperation: An async operation to perform for the client side of the test.
    ///         The ``MQTTConnection`` will be passed as a parameter to this operation.
    ///   - serverOperation: An async operation to perform for the server side of the test.
    ///         The test MQTT server channel will be passed as a parameter to this operation.
    func withTestMQTTServer(
        configuration: MQTTConnectionConfiguration = .init(),
        session: MQTTSession = MQTTSession(clientID: "", logger: Logger(label: "test_session")),
        logger: Logger,
        connackProperties: MQTTProperties = .init(),
        client clientOperation: @Sendable @escaping (MQTTConnection) async throws -> Void,
        server serverOperation: @Sendable @escaping (NIOAsyncTestingChannel) async throws -> Void,
    ) async throws {
        let channel = NIOAsyncTestingChannel()
        let connection = try await MQTTConnection.setupChannelAndConnect(
            channel,
            configuration: configuration,
            session: session,
            logger: logger
        )
        let version = configuration.version
        return try await withThrowingTaskGroup { group in
            group.addTask {
                do {
                    _ = try await connection.sendConnect(clientID: session.clientID, cleanSession: session.clientID.isEmpty)
                    try await withThrowingTaskGroup { group in
                        group.addTask { try await connection.handleSessionSubscriptionTasks() }
                        defer { group.cancelAll() }
                        try await clientOperation(connection)
                    }
                    await connection.saveInflightToSession()
                    connection.close()
                } catch {
                    await connection.saveInflightToSession()
                    connection.close()
                    throw error
                }
            }
            group.addTask {
                // Wait for CONNECT
                let packet = try await channel.waitForOutboundPacket()
                let connect = try MQTTConnectPacket.read(version: configuration.version, from: packet)
                #expect(connect.cleanSession == session.clientID.isEmpty)
                #expect(connect.clientIdentifier == session.clientID)
                if case .v5_0(var connectProperties, _, _, let authWorkflow) = configuration.versionConfiguration {
                    if let authWorkflow {
                        connectProperties.append(.authenticationMethod(authWorkflow.methodName))
                    }
                    #expect(connectProperties == connect.properties)
                }

                let connack = MQTTConnAckPacket(returnCode: 0, acknowledgeFlags: 1, properties: connackProperties)
                try await channel.writeInboundPacket(connack, version: version)

                try await serverOperation(channel)

                // Wait for DISCONNECT
                let disconnectPacket = try await channel.waitForOutboundPacket()
                #expect(disconnectPacket.type == .DISCONNECT)
                #expect(disconnectPacket.packetId == 0)
            }
            try await group.waitForAll()
        }
    }

    /// Helper function to create a ``MQTTSubscription`` with a test MQTT server.
    ///
    /// - Parameters:
    ///   - subscribeInfos: An array of ``MQTTSubscribeInfo`` to subscribe to for this subscription.
    ///   - cleanSession: Whether to use a clean session for the connection.
    ///   - identifier: The client identifier to use for the connection. If not provided, a random UUID string will be used.
    ///   - logger: The logger to use for the test MQTT server.
    ///   - clientOperation: An async operation to perform for the subscription opened via the connection.
    ///         The opened subscription will be passed as a parameter to this operation.
    ///   - serverOperation: An async operation to perform for the subscription on the server side.
    ///         The test MQTT server channel will be passed as a parameter to this operation.
    func withTestSubscription(
        subscribeInfos: [MQTTSubscribeInfo],
        cleanSession: Bool = true,
        identifier: String = UUID().uuidString,
        logger: Logger,
        client clientOperation: @Sendable @escaping (MQTTSubscription) async throws -> Void,
        server serverOperation: @Sendable @escaping (NIOAsyncTestingChannel) async throws -> Void,
    ) async throws {
        try await withTestMQTTServer(logger: logger) { connection in
            try await connection.subscribe(to: subscribeInfos) { sub in
                try await clientOperation(sub)
            }
        } server: { channel in
            // Receive SUBSCRIBE
            var packet = try await channel.waitForOutboundPacket()
            let subscribePacket = try MQTTSubscribePacket.read(version: .v3_1_1, from: packet)
            #expect(subscribeInfos.count == subscribePacket.subscriptions.count)
            for index in 0..<subscribePacket.subscriptions.count {
                #expect(subscribePacket.subscriptions[index].topicFilter == subscribeInfos[index].topicFilter)
                #expect(subscribePacket.subscriptions[index].qos == subscribeInfos[index].qos)
            }
            // Send SUBACK
            let suback = MQTTSubAckPacket(
                type: .SUBACK,
                packetId: subscribePacket.packetId,
                reasons: subscribeInfos.map { _ in .success },
                properties: .init()
            )
            try await channel.writeInboundPacket(suback, version: .v3_1_1)

            try await serverOperation(channel)

            // Receive UNSUBSCRIBE
            packet = try await channel.waitForOutboundPacket()
            let unsubscribePacket = try MQTTUnsubscribePacket.read(version: .v3_1_1, from: packet)
            #expect(unsubscribePacket.subscriptions == subscribeInfos.map { $0.topicFilter })
            // Send UNSUBACK
            let unsuback = MQTTSubAckPacket(
                type: .UNSUBACK,
                packetId: unsubscribePacket.packetId,
                reasons: subscribeInfos.map { _ in .success },
                properties: .init()
            )
            try await channel.writeInboundPacket(unsuback, version: .v3_1_1)
        }
    }

    /// Helper function to create a ``MQTTSubscription`` with a test MQTT server using MQTT v5.
    ///
    /// - Parameters:
    ///   - subscribeInfos: An array of ``MQTTSubscribeInfoV5`` to subscribe to for this subscription.
    ///   - cleanSession: Whether to use a clean session for the connection.
    ///   - identifier: The client identifier to use for the connection. If not provided, a random UUID string will be used.
    ///   - logger: The logger to use for the test MQTT server.
    ///   - clientOperation: An async operation to perform for the subscription opened via the connection.
    ///         The opened subscription will be passed as a parameter to this operation.
    ///   - serverOperation: An async operation to perform for the subscription on the server side.
    ///         The test MQTT server channel will be passed as a parameter to this operation.
    ///         The subscription identifier will also be passed as a parameter.
    func withTestV5Subscription(
        subscribeInfos: [MQTTSubscribeInfoV5],
        cleanSession: Bool = true,
        identifier: String = UUID().uuidString,
        logger: Logger,
        client clientOperation: @Sendable @escaping (MQTTSubscription) async throws -> Void,
        server serverOperation: @Sendable @escaping (NIOAsyncTestingChannel, UInt32) async throws -> Void,
    ) async throws {
        try await withTestMQTTServer(configuration: .init(versionConfiguration: .v5_0()), logger: logger) { connection in
            try await connection.v5.subscribe(to: subscribeInfos) { sub in
                try await clientOperation(sub)
            }
        } server: { channel in
            // Receive SUBSCRIBE
            var packet = try await channel.waitForOutboundPacket()
            let subscribePacket = try MQTTSubscribePacket.read(version: .v5_0, from: packet)
            #expect(subscribeInfos.count == subscribePacket.subscriptions.count)
            for index in 0..<subscribePacket.subscriptions.count {
                #expect(subscribePacket.subscriptions[index].topicFilter == subscribeInfos[index].topicFilter)
                #expect(subscribePacket.subscriptions[index].qos == subscribeInfos[index].qos)
            }
            let properties = try #require(subscribePacket.properties)
            let subscriptionId: UInt32 = try #require(
                {
                    for property in properties {
                        if case .subscriptionIdentifier(let id) = property {
                            return id
                        }
                    }
                    return nil
                }()
            )
            // Send SUBACK
            let suback = MQTTSubAckPacket(
                type: .SUBACK,
                packetId: subscribePacket.packetId,
                reasons: subscribeInfos.map { _ in .success },
                properties: .init()
            )
            try await channel.writeInboundPacket(suback, version: .v5_0)

            try await serverOperation(channel, subscriptionId)

            // Receive UNSUBSCRIBE
            packet = try await channel.waitForOutboundPacket()
            let unsubscribePacket = try MQTTUnsubscribePacket.read(version: .v5_0, from: packet)
            #expect(unsubscribePacket.subscriptions == subscribeInfos.map { $0.topicFilter })
            // Send UNSUBACK
            let unsuback = MQTTSubAckPacket(
                type: .UNSUBACK,
                packetId: unsubscribePacket.packetId,
                reasons: subscribeInfos.map { _ in .success },
                properties: .init()
            )
            try await channel.writeInboundPacket(unsuback, version: .v5_0)
        }
    }

    /// Helper function to test multiple ``MQTTSession`` subscriptions with a test MQTT server.
    ///
    /// For each array of ``MQTTSubscribeInfoV5``, a session subscription will be created
    /// and the same `clientOperation` and `serverOperation` will be performed for each subscription.
    ///
    /// - Parameters:
    ///   - subscribeInfos: An array of arrays of ``MQTTSubscribeInfoV5`` to subscribe to.
    ///         Each inner array represents a separate subscription.
    ///   - session: The ``MQTTSession`` to use for opening the subscriptions.
    ///   - logger: The logger to use for the test MQTT server.
    ///   - subscribeOperation: An async operation to perform for each subscription opened via the session.
    ///         The opened subscription will be passed as a parameter to this operation.
    ///   - clientOperation: An async operation to perform for the client side of the test.
    ///         The ``MQTTConnection`` will be passed as a parameter to this operation.
    ///   - serverOperation: An async operation to perform for each subscription on the server side.
    ///         The test MQTT server channel will be passed as a parameter to this operation.
    func withTestSessionSubscriptions(
        to subscribeInfos: [[MQTTSubscribeInfoV5]],
        session: MQTTSession,
        logger: Logger,
        subscribe subscribeOperation: @Sendable @escaping (MQTTSubscription) async throws -> Void,
        client clientOperation: @Sendable @escaping (MQTTConnection) async throws -> Void,
        server serverOperation: @Sendable @escaping (NIOAsyncTestingChannel) async throws -> Void
    ) async throws {
        try await withTestMQTTServer(session: session, logger: logger) { connection in
            await withThrowingTaskGroup { group in
                group.addTask { try await clientOperation(connection) }
                for subscribeInfo in subscribeInfos {
                    group.addTask {
                        try await session.subscribe(to: subscribeInfo) { subscription in
                            try await subscribeOperation(subscription)
                        }
                    }
                }
            }
        } server: { channel in
            for _ in subscribeInfos {
                // Receive SUBSCRIBE
                let packet = try await channel.waitForOutboundPacket()
                let subscribePacket = try MQTTSubscribePacket.read(version: .v3_1_1, from: packet)
                // Send SUBACK
                let suback = MQTTSubAckPacket(
                    type: .SUBACK,
                    packetId: subscribePacket.packetId,
                    reasons: subscribeInfos.map { _ in .success },
                    properties: .init()
                )
                try await channel.writeInboundPacket(suback, version: .v3_1_1)
            }

            try await serverOperation(channel)

            for _ in subscribeInfos {
                // Receive UNSUBSCRIBE
                let packet = try await channel.waitForOutboundPacket()
                let unsubscribePacket = try MQTTUnsubscribePacket.read(version: .v3_1_1, from: packet)
                // Send UNSUBACK
                let unsuback = MQTTSubAckPacket(
                    type: .UNSUBACK,
                    packetId: unsubscribePacket.packetId,
                    reasons: subscribeInfos.map { _ in .success },
                    properties: .init()
                )
                try await channel.writeInboundPacket(unsuback, version: .v3_1_1)
            }
        }
    }

    /// Helper function to test a ``MQTTSession`` subscription with a test MQTT server.
    ///
    /// - Parameters:
    ///   - subscribeInfos: An array of ``MQTTSubscribeInfoV5`` to subscribe to for this subscription.
    ///   - session: The ``MQTTSession`` to use for opening the subscription.
    ///   - logger: The logger to use for the test MQTT server.
    ///   - subscribeOperation: An async operation to perform for the subscription opened via the session.
    ///         The opened subscription will be passed as a parameter to this operation.
    ///   - clientOperation: An async operation to perform for the client side of the test.
    ///         The ``MQTTConnection`` will be passed as a parameter to this operation.
    ///   - serverOperation: An async operation to perform for the subscription on the server side.
    ///         The test MQTT server channel will be passed as a parameter to this operation.
    func withTestSessionSubscription(
        to subscribeInfos: [MQTTSubscribeInfoV5],
        session: MQTTSession,
        logger: Logger,
        subscribe subscribeOperation: @Sendable @escaping (MQTTSubscription) async throws -> Void,
        client clientOperation: @Sendable @escaping (MQTTConnection) async throws -> Void,
        server serverOperation: @Sendable @escaping (NIOAsyncTestingChannel) async throws -> Void
    ) async throws {
        try await withTestSessionSubscriptions(
            to: [subscribeInfos],
            session: session,
            logger: logger,
            subscribe: subscribeOperation,
            client: clientOperation,
            server: serverOperation
        )
    }
}
