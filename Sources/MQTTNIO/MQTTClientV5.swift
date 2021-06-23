import NIO

extension MQTTClient {
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
            will: (topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool, properties: MQTTProperties)? = nil
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
                clientIdentifier: client.identifier,
                userName: client.configuration.userName,
                password: client.configuration.password,
                properties: properties,
                will: publish
            )

            return client.connect(packet: packet).map {
                .init(
                    sessionPresent: $0.acknowledgeFlags & 0x1 == 0x1,
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
            let packetId = client.updatePacketId()
            let packet = MQTTPublishPacket(publish: info, packetId: packetId)
            return client.publish(packet: packet)
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
            let packetId = client.updatePacketId()
            let packet = MQTTSubscribePacket(subscriptions: subscriptions, properties: properties, packetId: packetId)
            return client.subscribe(packet: packet)
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
            let packetId = client.updatePacketId()
            let packet = MQTTUnsubscribePacket(subscriptions: subscriptions, properties: .init(), packetId: packetId)
            return client.unsubscribe(packet: packet)
                .map { message in
                    return MQTTSubackV5(reasons: message.reasons, properties: message.properties)
                }
        }

        /// Disconnect from server
        /// - Parameter properties: properties to attach to disconnect message
        /// - Returns: Future waiting on disconnect message to be sent
        public func disconnect(properties: MQTTProperties = .init()) -> EventLoopFuture<Void> {
            return client.disconnect(packet: MQTTDisconnectPacket(reason: .success, properties: properties))
        }

    }

    /// v5 client
    public var v5: V5 {
        precondition(self.configuration.version == .v5_0, "Cannot use v5 functions with v3.1 client")
        return V5(client: self)
    }
}
