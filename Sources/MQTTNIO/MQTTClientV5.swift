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

import MQTTTypes
import NIO

extension MQTTClient {
    /// Provides implementations of functions that expose MQTT Version 5.0 features
    public struct V5 {
        let client: MQTTClient

        /// Connect to MQTT server
        ///
        /// If `cleanSession` is set to false the Server MUST resume communications with the Client based on state from the current Session (as identified by the Client identifier).
        /// If there is no Session associated with the Client identifier the Server MUST create a new Session. The Client and Server MUST store the Session
        /// after the Client and Server are disconnected. If set to true then the Client and Server MUST discard any previous Session and start a new one
        ///
        /// The function returns an EventLoopFuture which will be updated with whether the server has restored a session for this client.
        ///
        /// - Parameters:
        ///   - cleanSession: should we start with a new session
        ///   - properties: properties to attach to connect message
        ///   - will: Publish message to be posted as soon as connection is made
        /// - Returns: EventLoopFuture to be updated with connack
        public func connect(
            cleanStart: Bool = true,
            properties: MQTTProperties = .init(),
            will: (topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool, properties: MQTTProperties)? = nil,
            authWorkflow: ((MQTTAuthV5, EventLoop) -> EventLoopFuture<MQTTAuthV5>)? = nil
        ) -> EventLoopFuture<MQTTConnackV5> {
            let publish = will.map {
                MQTTPublishInfo(
                    qos: .atMostOnce,
                    retain: $0.retain,
                    dup: false,
                    topicName: $0.topicName,
                    payload: $0.payload,
                    properties: $0.properties
                )
            }
            let packet = MQTTConnectPacket(
                cleanSession: cleanStart,
                keepAliveSeconds: UInt16(client.configuration.keepAliveInterval.nanoseconds / 1_000_000_000),
                clientIdentifier: self.client.identifier,
                userName: self.client.configuration.userName,
                password: self.client.configuration.password,
                properties: properties,
                will: publish
            )

            return self.client.connect(packet: packet).map {
                .init(
                    sessionPresent: $0.sessionPresent,
                    reason: MQTTReasonCode(rawValue: $0.returnCode) ?? .unrecognisedReason,
                    properties: $0.properties
                )
            }
        }

        /// Publish message to topic
        /// - Parameters:
        ///     - topicName: Topic name on which the message is published
        ///     - payload: Message payload
        ///     - qos: Quality of Service for message.
        ///     - retain: Whether this is a retained message.
        ///     - properties: properties to attach to publish message
        /// - Returns: Future waiting for publish to complete. Depending on QoS setting the future will complete
        ///     when message is sent, when PUBACK is received or when PUBREC and following PUBCOMP are
        ///     received. QoS1 and above return an `MQTTAckV5` which contains a `reason` and `properties`
        public func publish(
            to topicName: String,
            payload: ByteBuffer,
            qos: MQTTQoS,
            retain: Bool = false,
            properties: MQTTProperties = .init()
        ) -> EventLoopFuture<MQTTAckV5?> {
            let info = MQTTPublishInfo(qos: qos, retain: retain, dup: false, topicName: topicName, payload: payload, properties: properties)
            let packetId = self.client.updatePacketId()
            let packet = MQTTPublishPacket(publish: info, packetId: packetId)
            return self.client.publish(packet: packet)
        }

        /// Subscribe to topic
        /// - Parameters:
        ///     - subscriptions: Subscription infos
        ///     - properties: properties to attach to subscribe message
        /// - Returns: Future waiting for subscribe to complete. Will wait for SUBACK message from server and
        ///     return its contents
        public func subscribe(
            to subscriptions: [MQTTSubscribeInfoV5],
            properties: MQTTProperties = .init()
        ) -> EventLoopFuture<MQTTSubackV5> {
            let packetId = self.client.updatePacketId()
            let packet = MQTTSubscribePacket(subscriptions: subscriptions, properties: properties, packetId: packetId)
            return self.client.subscribe(packet: packet)
                .map { message in
                    return MQTTSubackV5(reasons: message.reasons, properties: message.properties)
                }
        }

        /// Unsubscribe from topic
        /// - Parameters:
        ///   - subscriptions: List of subscriptions to unsubscribe from
        ///   - properties: properties to attach to unsubscribe message
        /// - Returns: Future waiting for unsubscribe to complete. Will wait for UNSUBACK message from server and
        ///     return its contents
        public func unsubscribe(
            from subscriptions: [String],
            properties: MQTTProperties = .init()
        ) -> EventLoopFuture<MQTTSubackV5> {
            let packetId = self.client.updatePacketId()
            let packet = MQTTUnsubscribePacket(subscriptions: subscriptions, properties: .init(), packetId: packetId)
            return self.client.unsubscribe(packet: packet)
                .map { message in
                    return MQTTSubackV5(reasons: message.reasons, properties: message.properties)
                }
        }

        /// Disconnect from server
        /// - Parameter properties: properties to attach to disconnect packet
        /// - Returns: Future waiting on disconnect message to be sent
        public func disconnect(properties: MQTTProperties = .init()) -> EventLoopFuture<Void> {
            return self.client.disconnect(packet: MQTTDisconnectPacket(reason: .success, properties: properties))
        }

        /// Re-authenticate with server
        ///
        /// - Parameters:
        ///   - properties: properties to attach to auth packet. Must include `authenticationMethod`
        ///   - authWorkflow: Respond to auth packets from server
        /// - Returns: final auth packet returned from server
        public func auth(
            properties: MQTTProperties,
            authWorkflow: ((MQTTAuthV5, EventLoop) -> EventLoopFuture<MQTTAuthV5>)? = nil
        ) -> EventLoopFuture<MQTTAuthV5> {
            let authPacket = MQTTAuthPacket(reason: .reAuthenticate, properties: properties)
            let authFuture = self.client.reAuth(packet: authPacket)
            let eventLoop = authFuture.eventLoop
            return authFuture.flatMap { response -> EventLoopFuture<MQTTPacket> in
                guard let auth = response as? MQTTAuthPacket else { return eventLoop.makeFailedFuture(MQTTError.unexpectedMessage) }
                if auth.reason == .success {
                    return eventLoop.makeSucceededFuture(auth)
                }
                guard let authWorkflow = authWorkflow else { return eventLoop.makeFailedFuture(MQTTError.authWorkflowRequired) }
                return client.processAuth(authPacket, authWorkflow: authWorkflow, on: eventLoop)
            }
            .flatMapThrowing { response -> MQTTAuthV5 in
                guard let auth = response as? MQTTAuthPacket else { throw MQTTError.unexpectedMessage }
                return MQTTAuthV5(reason: auth.reason, properties: auth.properties)
            }
        }

        /// Add named publish listener. Called whenever a PUBLISH message is received from the server with the
        /// specified subscription id
        ///
        /// - Parameters:
        ///   - name: Name of listener
        ///   - subscriptionIdentifier: subscription identifier to look for
        ///   - listener: listener function
        public func addPublishListener(named name: String, subscriptionId: UInt, _ listener: @escaping (MQTTPublishInfo) -> Void) {
            self.client.publishListeners.addListener(named: name) { result in
                if case .success(let info) = result {
                    for property in info.properties {
                        if case .subscriptionIdentifier(let id) = property,
                           id == subscriptionId
                        {
                            listener(info)
                            break
                        }
                    }
                }
            }
        }
    }

    /// v5 client
    public var v5: V5 {
        precondition(self.configuration.version == .v5_0, "Cannot use v5 functions with v3.1 client")
        return V5(client: self)
    }
}
