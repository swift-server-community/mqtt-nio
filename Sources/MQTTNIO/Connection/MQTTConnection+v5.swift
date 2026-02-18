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

public import NIOCore

extension MQTTConnection {
    /// Provides implementations of functions that expose MQTT Version 5.0 features.
    public struct V5: Sendable {
        @usableFromInline
        let connection: MQTTConnection

        /// Publish message to topic.
        ///
        /// - Parameters:
        ///     - topicName: Topic name on which the message is published.
        ///     - payload: Message payload.
        ///     - qos: Quality of Service for message.
        ///     - retain: Whether this is a retained message.
        ///     - properties: Properties to attach to publish message.
        ///
        /// - Returns: QoS1 and above return an `MQTTAckV5` which contains a `reason` and `properties`.
        public func publish(
            to topicName: String,
            payload: ByteBuffer,
            qos: MQTTQoS,
            retain: Bool = false,
            properties: MQTTProperties = .init()
        ) async throws -> MQTTAckV5? {
            let info = MQTTPublishInfo(qos: qos, retain: retain, dup: false, topicName: topicName, payload: payload, properties: properties)
            let packetId = await self.connection.updatePacketId()
            let packet = MQTTPublishPacket(publish: info, packetId: packetId)
            return try await self.connection.publish(packet: packet)
        }

        /// Re-authenticate with server.
        ///
        /// - Parameters:
        ///   - properties: Properties to attach to auth packet. The `authenticationMethod` will be added by this function
        ///     so there is no need to include it here.
        ///   - authWorkflow: Respond to auth packets from server.
        ///
        /// - Returns: Final auth packet returned from server.
        public func auth(
            properties: MQTTProperties,
            authWorkflow: (any MQTTAuthenticator)? = nil
        ) async throws -> MQTTAuthV5 {
            guard
                let authWorkflow: any MQTTAuthenticator =
                    switch self.connection.configuration.versionConfiguration {
                    case .v3_1_1:
                        nil
                    case .v5_0(_, _, _, let configuredAuthWorkflow):
                        authWorkflow ?? configuredAuthWorkflow
                    }
            else {
                throw MQTTError.authWorkflowRequired
            }
            var properties = properties
            properties.addOrReplace(.authenticationMethod(authWorkflow.methodName))
            let authPacket = MQTTAuthPacket(reason: .reAuthenticate, properties: properties)
            // Send AUTH
            let reAuthResponse = try await self.connection.sendMessage(authPacket) { message in
                guard message.type == .AUTH else { return false }
                return true
            }
            guard let authResponse = reAuthResponse as? MQTTAuthPacket else { throw MQTTError.unexpectedMessage }
            if authResponse.reason == .success {
                return MQTTAuthV5(reason: authResponse.reason, properties: authResponse.properties)
            }
            // Process AUTH response
            guard let auth = try await self.connection.processAuth(authResponse, authWorkflow: authWorkflow) as? MQTTAuthPacket else {
                throw MQTTError.unexpectedMessage
            }
            return MQTTAuthV5(reason: auth.reason, properties: auth.properties)
        }
    }

    /// Access MQTT v5 functionality.
    public nonisolated var v5: V5 {
        get throws {
            guard self.configuration.version == .v5_0 else {
                throw MQTTError.versionMismatch(expected: .v5_0, actual: self.configuration.version)
            }
            return V5(connection: self)
        }
    }
}
