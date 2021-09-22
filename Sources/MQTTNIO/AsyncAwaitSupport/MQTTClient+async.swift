#if compiler(>=5.5) && canImport(_Concurrency)

import _NIOConcurrency
import NIO

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension MQTTClient {
    /// Connect to MQTT server
    ///
    /// Completes when CONNACK is received
    ///
    /// If `cleanSession` is set to false the Server MUST resume communications with the Client based on state from the current Session (as identified by the Client identifier).
    /// If there is no Session associated with the Client identifier the Server MUST create a new Session. The Client and Server MUST store the Session
    /// after the Client and Server are disconnected. If set to true then the Client and Server MUST discard any previous Session and start a new one
    ///
    /// The function returns an EventLoopFuture which will be updated with whether the server has restored a session for this client.
    ///
    /// - Parameters:
    ///   - cleanSession: should we start with a new session
    ///   - will: Publish message to be posted as soon as connection is made
    /// - Returns: Whether server holds a session for this client
    @discardableResult public func connect(
        cleanSession: Bool = true,
        will: (topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool)? = nil
    ) async throws -> Bool {
        return try await self.connect(cleanSession: cleanSession, will: will).get()
    }

    /// Publish message to topic
    ///
    /// Depending on QoS completes when message is sent, when PUBACK is received or when PUBREC
    /// and following PUBCOMP are received
    ///
    /// Waits for publish to complete. Depending on QoS setting the future will complete
    /// when message is sent, when PUBACK is received or when PUBREC and following PUBCOMP are
    /// received
    /// - Parameters:
    ///     - topicName: Topic name on which the message is published
    ///     - payload: Message payload
    ///     - qos: Quality of Service for message.
    ///     - retain: Whether this is a retained message.
    public func publish(to topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool = false) async throws {
        return try await self.publish(to: topicName, payload: payload, qos: qos).get()
    }

    /// Subscribe to topic
    ///
    /// Completes when SUBACK is received
    /// - Parameter subscriptions: Subscription infos
    public func subscribe(to subscriptions: [MQTTSubscribeInfo]) async throws -> MQTTSuback {
        return try await self.subscribe(to: subscriptions).get()
    }

    /// Unsubscribe from topic
    ///
    /// Completes when UNSUBACK is received
    /// - Parameter subscriptions: List of subscriptions to unsubscribe from
    public func unsubscribe(from subscriptions: [String]) async throws {
        return try await unsubscribe(from: subscriptions).get()
    }

    /// Ping the server to test if it is still alive and to tell it you are alive.
    ///
    /// Completes when PINGRESP is received
    ///
    /// You shouldn't need to call this as the `MQTTClient` automatically sends PINGREQ messages to the server to ensure
    /// the connection is still live. If you initialize the client with the configuration `disablePingReq: true` then these
    /// are disabled and it is up to you to send the PINGREQ messages yourself
    public func ping() async throws {
        return try await ping().get()
    }

    /// Disconnect from server
    public func disconnect() async throws {
        return try await disconnect().get()
    }

}

#endif // compiler(>=5.5)

