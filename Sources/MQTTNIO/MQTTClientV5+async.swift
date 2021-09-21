#if compiler(>=5.5)

import _NIOConcurrency
import NIO

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension MQTTClient.V5 {
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
    ) async throws -> MQTTConnackV5 {
        return try await connect(cleanStart: cleanStart, properties: properties, will: will, authWorkflow: authWorkflow).get()
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
    ) async throws -> MQTTAckV5? {
        return try await publish(to: topicName, payload: payload, qos: qos, retain: retain, properties: properties).get()
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
    ) async throws -> MQTTSubackV5 {
        return try await subscribe(to: subscriptions, properties: properties).get()
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
    ) async throws -> MQTTSubackV5 {
        return try await unsubscribe(from: subscriptions, properties: properties).get()
    }

    /// Disconnect from server
    /// - Parameter properties: properties to attach to disconnect packet
    /// - Returns: Future waiting on disconnect message to be sent
    public func disconnect(properties: MQTTProperties = .init()) async throws {
        return try await disconnect(properties: properties).get()
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
    ) async throws -> MQTTAuthV5 {
        return try await auth(properties: properties, authWorkflow: authWorkflow).get()
    }
}

#endif // compiler(>=5.5)
