//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

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
        do {
            try await session.storage.mutatingBorrow { sessionStorage -> (MQTTSessionStorage, Result<Void, any Error>) in
                let connection: MQTTConnection
                do {
                    connection = try await MQTTConnection.setupChannelAndConnect(
                        channel,
                        configuration: configuration,
                        session: sessionStorage,
                        logger: logger
                    )
                } catch {
                    return (sessionStorage, .failure(error))
                }
                let version = configuration.version
                return await withTaskGroup(of: (MQTTSessionStorage, Result<Void, any Error>).self) { group in
                    group.addTask {
                        do {
                            _ = try await connection.sendConnect(clientID: sessionStorage.clientID, cleanSession: sessionStorage.clientID.isEmpty)
                        } catch {
                            let sessionStorage = await connection.closeAndCleanup(sendDisconnect: false)
                            return (sessionStorage, .failure(error))
                        }
                        // stick this in an unstructured task to avoid cancellation on iterating the subscribe
                        // request queue. TODO: use `withTaskCancellationShield` when Swift 6.4 comes out
                        let task = Task { await connection.handleSessionSubscriptionTasks(session: session) }
                        do {
                            try await clientOperation(connection)
                            session.subscriptionsQueueContinuation.yield(.cancel)
                            await task.value
                            let sessionStorage = await connection.closeAndCleanup()
                            return (sessionStorage, .success(()))
                        } catch {
                            session.subscriptionsQueueContinuation.yield(.cancel)
                            await task.value
                            let sessionStorage = await connection.closeAndCleanup()
                            return (sessionStorage, .failure(error))
                        }
                    }
                    do {
                        // wait for connect
                        let packet = try await channel.waitForOutboundPacket()
                        let connect = try MQTTConnectPacket.read(version: configuration.version, from: packet)
                        #expect(connect.cleanSession == sessionStorage.clientID.isEmpty)
                        #expect(connect.clientIdentifier == sessionStorage.clientID)
                        if case .v5_0(var connectProperties, _, _, let authWorkflow) = configuration.versionConfiguration {
                            if let authWorkflow {
                                connectProperties.append(.authenticationMethod(authWorkflow.methodName))
                            }
                            #expect(connectProperties == connect.properties)
                        }

                        let connack = MQTTConnAckPacket(returnCode: 0, acknowledgeFlags: 1, properties: connackProperties)
                        try await channel.writeInboundPacket(connack, version: version)

                        try await serverOperation(channel)

                        // wait for disconnect
                        let disconnectPacket = try await channel.waitForOutboundPacket()
                        #expect(disconnectPacket.type == .DISCONNECT)
                        #expect(disconnectPacket.packetId == 0)
                    } catch {
                        return (sessionStorage, .failure(error))
                    }

                    return await group.next()!
                }
            }
        } catch UniqueReferenceError.alreadyBorrowed {
            throw MQTTError.alreadyConnectedWithSession
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
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        try await withTestMQTTServer(session: session, logger: logger) { connection in
            try await withThrowingTaskGroup { group in
                for subscribeInfo in subscribeInfos {
                    group.addTask {
                        try await session.subscribe(to: subscribeInfo) { subscription in
                            try await subscribeOperation(subscription)
                        }
                    }
                }
                // Make sure all subscriptions have been called before running
                // client operation
                await stream.first { _ in true }
                try await clientOperation(connection)
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
            cont.yield()
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
