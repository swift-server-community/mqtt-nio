import Logging
import NIOCore
import NIOEmbedded
import Testing

@testable import MQTTNIO

extension MQTTConnectionTests {
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
    ///   - clientOperation: An async operation to perform for each subscription opened via the session.
    ///         The opened subscription will be passed as a parameter to this operation.
    ///   - serverOperation: An async operation to perform for each subscription on the server side.
    ///         The test MQTT server channel will be passed as a parameter to this operation.
    func withTestSessionSubscriptions(
        to subscribeInfos: [[MQTTSubscribeInfoV5]],
        session: MQTTSession,
        logger: Logger,
        client clientOperation: @Sendable @escaping (MQTTSubscription) async throws -> Void,
        server serverOperation: @Sendable @escaping (NIOAsyncTestingChannel) async throws -> Void
    ) async throws {
        try await withTestMQTTServer(session: session, logger: logger) { connection in
            await withThrowingTaskGroup { group in
                for subscribeInfo in subscribeInfos {
                    group.addTask {
                        try await session.subscribe(to: subscribeInfo) { subscription in
                            try await clientOperation(subscription)
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
    ///   - clientOperation: An async operation to perform for the subscription opened via the session.
    ///         The opened subscription will be passed as a parameter to this operation.
    ///   - serverOperation: An async operation to perform for the subscription on the server side.
    ///         The test MQTT server channel will be passed as a parameter to this operation.
    func withTestSessionSubscription(
        to subscribeInfos: [MQTTSubscribeInfoV5],
        session: MQTTSession,
        logger: Logger,
        client clientOperation: @Sendable @escaping (MQTTSubscription) async throws -> Void,
        server serverOperation: @Sendable @escaping (NIOAsyncTestingChannel) async throws -> Void
    ) async throws {
        try await withTestSessionSubscriptions(
            to: [subscribeInfos],
            session: session,
            logger: logger,
            client: clientOperation,
            server: serverOperation
        )
    }
}
