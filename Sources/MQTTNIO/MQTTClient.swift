import Foundation
import Logging
#if canImport(Network)
import Network
#endif
import NIO
import NIOConcurrencyHelpers
#if canImport(NIOSSL)
import NIOSSL
#endif
import NIOTransportServices

/// Swift NIO MQTT Client
final public class MQTTClient {
    /// MQTTClient errors
    enum Error: Swift.Error {
        /// You called connect on a client that is already connected to the broker
        case alreadyConnected
        /// We received an unexpected message while connecting
        case failedToConnect
        /// client in not connected
        case noConnection
        /// the server closed the connection
        case serverClosedConnection
        /// received unexpected message from broker
        case unexpectedMessage
        /// Decode of MQTT message failed
        case decodeError
        /// Upgrade to websocker failed
        case websocketUpgradeFailed
        /// client timed out while waiting for response from server
        case timeout
        /// Internal error, used to get the client to retry sending
        case retrySend
        /// You have provided the wrong TLS configuration for the EventLoopGroup you provided
        case wrongTLSConfig
    }
    
    /// EventLoopGroup used by MQTTCllent
    public let eventLoopGroup: EventLoopGroup
    /// How was EventLoopGroup provided to the client
    let eventLoopGroupProvider: NIOEventLoopGroupProvider
    /// Host name of server to connect to
    public let host: String
    /// Port to connect to
    public let port: Int
    /// client identifier
    public let identifier: String
    /// logger
    public var logger: Logger
    /// Client configuration
    public let configuration: Configuration

    /// Connection client is using
    var connection: MQTTConnection? {
        get {
            lock.withLock {
                _connection
            }
        }
        set {
            lock.withLock {
                _connection = newValue
            }
        }
    }

    private let globalPacketId = NIOAtomic<UInt16>.makeAtomic(value: 1)
    /// default logger that logs nothing
    private static let loggingDisabled = Logger(label: "MQTT-do-not-log", factory: { _ in SwiftLogNoOpLogHandler() })
    
    /// Create MQTT client
    /// - Parameters:
    ///   - host: host name
    ///   - port: port to connect on
    ///   - eventLoopGroupProvider: EventLoopGroup to run on
    ///   - configuration: Configuration of client
    ///   - publishCallback: called whenever there is a publish event
    public init(
        host: String,
        port: Int? = nil,
        identifier: String,
        eventLoopGroupProvider: NIOEventLoopGroupProvider,
        logger: Logger? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.host = host
        if let port = port {
            self.port = port
        } else {
            switch (configuration.useSSL, configuration.useWebSockets){
            case (false, false):
                self.port = 1883
            case (true, false):
                self.port = 8883
            case (false, true):
                self.port = 80
            case (true, true):
                self.port = 443
            }
        }
        self.identifier = identifier
        self.configuration = configuration
        self._connection = nil
        self.logger = (logger ?? Self.loggingDisabled).attachingClientIdentifier(self.identifier)
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch eventLoopGroupProvider {
        case .createNew:
            #if canImport(Network)
            switch configuration.tlsConfiguration {
            #if canImport(NIOSSL)
            case .niossl:
                self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            #endif
            case .ts, .none:
                self.eventLoopGroup = NIOTSEventLoopGroup()
            }
            #else
                self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            #endif
        case.shared(let elg):
            self.eventLoopGroup = elg
        }
    }

    /// Close down client. Must be called before the client is destroyed
    public func syncShutdownGracefully() throws {
        try connection?.close().wait()
        switch self.eventLoopGroupProvider {
        case .createNew:
            try eventLoopGroup.syncShutdownGracefully()
        case .shared:
            break
        }
    }

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
    ///   - will: Publish message to be posted as soon as connection is made
    /// - Returns: EventLoopFuture to be updated with whether server holds a session for this client
    public func connect(
        cleanSession: Bool = true,
        will: (topicName: String, payload: ByteBuffer, retain: Bool)? = nil
    ) -> EventLoopFuture<Bool> {
        //guard self.connection == nil else { return eventLoopGroup.next().makeFailedFuture(Error.alreadyConnected) }

        let info = MQTTConnectInfo(
            cleanSession: cleanSession,
            keepAliveSeconds: UInt16(configuration.keepAliveInterval.nanoseconds / 1_000_000_000),
            clientIdentifier: self.identifier,
            userName: configuration.userName ?? "",
            password: configuration.password ?? ""
        )
        let publish = will.map { MQTTPublishInfo(qos: .atMostOnce, retain: $0.retain, dup: false, topicName: $0.topicName, payload: $0.payload) }

        // work out pingreq interval
        let pingInterval = configuration.pingInterval ?? TimeAmount.seconds(max(Int64(info.keepAliveSeconds - 5), 5))

        return MQTTConnection.create(client: self, pingInterval: pingInterval)
            .flatMap { connection -> EventLoopFuture<MQTTInboundMessage> in
                self.connection = connection
                connection.closeFuture.whenComplete { result in
                    // only reset connection if this connection is still set. Stops a reconnect having its connection removed by the
                    // previous connection
                    if self.connection === connection {
                        self.connection = nil
                    }
                    self.closeListeners.notify(result)
                }
                return connection.sendMessageWithRetry(MQTTConnectMessage(connect: info, will: publish), maxRetryAttempts: self.configuration.maxRetryAttempts) { message in
                    guard message.type == .CONNACK else { throw Error.failedToConnect }
                    return true
                }
            }
            .map { message in
                guard let connack = message as? MQTTConnAckMessage else { return false }
                _ = self.globalPacketId.exchange(with: connack.packetId + 32767)
                return connack.sessionPresent
            }
    }

    /// Publish message to topic
    /// - Parameters:
    ///     - topicName: Topic name on which the message is published
    ///     - payload: Message payload
    ///     - qos: Quality of Service for message.
    ///     - retain: Whether this is a retained message.
    /// - Returns: Future waiting for publish to complete. Depending on QoS setting the future will complete
    ///     when message is sent, when PUBACK is received or when PUBREC and following PUBCOMP are
    ///     received
    public func publish(to topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool = false) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }

        let info = MQTTPublishInfo(qos: qos, retain: retain, dup: false, topicName: topicName, payload: payload)
        if info.qos == .atMostOnce {
            // don't send a packet id if QOS is at most once. (MQTT-2.3.1-5)
            return connection.sendMessageNoWait(MQTTPublishMessage(publish: info, packetId: 0))
        }

        let packetId = self.updatePacketId()
        return connection.sendMessageWithRetry(MQTTPublishMessage(publish: info, packetId: packetId), maxRetryAttempts: configuration.maxRetryAttempts) { message in
            guard message.packetId == packetId else { return false }
            if info.qos == .atLeastOnce {
                guard message.type == .PUBACK else {
                    throw Error.unexpectedMessage
                }
            } else if info.qos == .exactlyOnce {
                guard message.type == .PUBREC else {
                    throw Error.unexpectedMessage
                }
            }
            return true
        }
        .flatMap { _ in
            if info.qos == .exactlyOnce {
                return connection.sendMessageWithRetry(MQTTAckMessage(type: .PUBREL, packetId: packetId), maxRetryAttempts: self.configuration.maxRetryAttempts) { message in
                    guard message.packetId == packetId else { return false }
                    guard message.type != .PUBREC else { return false }
                    guard message.type == .PUBCOMP else {
                        throw Error.unexpectedMessage
                    }
                    return true
                }.map { _ in }
            }
            return self.eventLoopGroup.next().makeSucceededFuture(())
        }
    }

    /// Subscribe to topic
    /// - Parameter subscriptions: Subscription infos
    /// - Returns: Future waiting for subscribe to complete. Will wait for SUBACK message from server
    public func subscribe(to subscriptions: [MQTTSubscribeInfo]) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
        let packetId = self.updatePacketId()

        return connection.sendMessageWithRetry(MQTTSubscribeMessage(subscriptions: subscriptions, packetId: packetId), maxRetryAttempts: configuration.maxRetryAttempts) { message in
            guard message.packetId == packetId else { return false }
            guard message.type == .SUBACK else { throw Error.unexpectedMessage }
            return true
        }
        .map { _ in }
    }

    /// Unsubscribe from topic
    /// - Parameter subscriptions: List of subscriptions to unsubscribe from
    /// - Returns: Future waiting for unsubscribe to complete. Will wait for UNSUBACK message from server
    public func unsubscribe(from subscriptions: [String]) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
        let packetId = self.updatePacketId()

        let subscribeInfos = subscriptions.map { MQTTSubscribeInfo(topicFilter: $0, qos: .atLeastOnce) }
        return connection.sendMessageWithRetry(MQTTUnsubscribeMessage(subscriptions: subscribeInfos, packetId: packetId), maxRetryAttempts: configuration.maxRetryAttempts) { message in
            guard message.packetId == packetId else { return false }
            guard message.type == .UNSUBACK else { throw Error.unexpectedMessage }
            return true
        }
        .map { _ in }
    }

    /// Ping the server to test if it is still alive and to tell it you are alive.
    ///
    /// You shouldn't need to call this as the `MQTTClient` automatically sends PINGREQ messages to the server to ensure
    /// the connection is still live. If you initialize the client with the configuration `disablePingReq: true` then these
    /// are disabled and it is up to you to send the PINGREQ messages yourself
    ///
    /// - Returns: Future waiting for ping response
    public func ping() -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }

        return connection.sendMessageWithRetry(MQTTPingreqMessage(), maxRetryAttempts: configuration.maxRetryAttempts) { message in
            guard message.type == .PINGRESP else { return false }
            return true
        }
        .map { _ in }
    }

    /// Disconnect from server
    /// - Returns: Future waiting on disconnect message to be sent
    public func disconnect() -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }

        return connection.sendMessageNoWait(MQTTDisconnectMessage())
            .flatMap {
                let future = self.connection?.close()
                self.connection = nil
                return future ?? self.eventLoopGroup.next().makeSucceededFuture(())
            }
    }

    /// Return is client has an active connection to broker
    public func isActive() -> Bool {
        return connection?.channel.isActive ?? false
    }

    /// Add named publish listener. Called whenever a PUBLISH message is received from the server
    public func addPublishListener(named name: String, _ listener: @escaping (Result<MQTTPublishInfo, Swift.Error>) -> ()) {
        publishListeners.addListener(named: name, listener: listener)
    }

    /// Remove named publish listener
    public func removePublishListener(named name: String) {
        publishListeners.removeListener(named: name)
    }

    /// Add close listener. Called whenever the connection is closed
    public func addCloseListener(named name: String, _ listener: @escaping (Result<Void, Swift.Error>) -> ()) {
        closeListeners.addListener(named: name, listener: listener)
    }

    /// Remove named close listener
    public func removeCloseListener(named name: String) {
        closeListeners.removeListener(named: name)
    }

    private func updatePacketId() -> UInt16 {
        // packet id must be non-zero
        if self.globalPacketId.compareAndExchange(expected: 0, desired: 1) {
            return 1
        } else {
            return self.globalPacketId.add(1)
        }
    }

    var publishListeners = MQTTListeners<MQTTPublishInfo>()
    var closeListeners = MQTTListeners<Void>()
    private var _connection: MQTTConnection?
    private var lock = Lock()
}

extension Logger {
    func attachingClientIdentifier(_ identifier: String?) -> Logger {
        var logger = self
        logger[metadataKey: "mqtt-client"] = identifier.map { .string($0) }
        return logger
    }
}
