import Foundation
import Logging
#if canImport(Network)
import Network
#endif
import NIO
import NIOConcurrencyHelpers
import NIOSSL
import NIOTransportServices

/// Swift NIO MQTT Client
final public class MQTTClient {
    /// MQTTClient errors
    enum Error: Swift.Error {
        case alreadyConnected
        case failedToConnect
        case noConnection
        case unexpectedMessage
        case decodeError
        case websocketUpgradeFailed
        case timeout
    }
    /// EventLoopGroup used by MQTTCllent
    let eventLoopGroup: EventLoopGroup
    /// How was EventLoopGroup provided to the client
    let eventLoopGroupProvider: NIOEventLoopGroupProvider
    /// Host name of server to connect to
    let host: String
    /// Port to connect to
    let port: Int
    /// client identifier
    let identifier: String
    /// logger
    var logger: Logger
    /// Client configuration
    let configuration: Configuration

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

    private static let globalPacketId = NIOAtomic<UInt16>.makeAtomic(value: 1)
    /// default logger that logs nothing
    private static let loggingDisabled = Logger(label: "MQTT-do-not-log", factory: { _ in SwiftLogNoOpLogHandler() })

    /// Configuration for MQTTClient
    public struct Configuration {
        public init(
            disablePing: Bool = false,
            keepAliveInterval: TimeAmount = .seconds(90),
            pingInterval: TimeAmount? = nil,
            timeout: TimeAmount? = nil,
            userName: String? = nil,
            password: String? = nil,
            useSSL: Bool = false,
            useWebSockets: Bool = false,
            tlsConfiguration: TLSConfiguration? = nil,
            webSocketURLPath: String? = nil
        ) {
            self.disablePing = disablePing
            self.keepAliveInterval = keepAliveInterval
            self.pingInterval = pingInterval
            self.timeout = timeout
            self.userName = userName
            self.password = password
            self.useSSL = useSSL
            self.useWebSockets = useWebSockets
            self.tlsConfiguration = tlsConfiguration
            self.webSocketURLPath = webSocketURLPath
        }

        /// disable the sending of pingreq messages
        public let disablePing: Bool
        /// MQTT keep alive period.
        public let keepAliveInterval: TimeAmount
        /// override interval between each pingreq message
        public let pingInterval: TimeAmount?
        /// timeout for server response
        public let timeout: TimeAmount?
        /// MQTT user name.
        public let userName: String?
        /// MQTT password.
        public let password: String?
        /// use encrypted connection to server
        public let useSSL: Bool
        /// use a websocket connection to server
        public let useWebSockets: Bool
        /// TLS configuration
        public let tlsConfiguration: TLSConfiguration?
        /// URL Path for web socket. Defaults to "/"
        public let webSocketURLPath: String?
    }

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
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)/*, configuration.tlsConfiguration == nil*/ {
                    self.eventLoopGroup = NIOTSEventLoopGroup()
                } else {
                    self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
    /// - Parameters:
    ///   - will: Publish message to be posted as soon as connection is made
    /// - Returns: Future waiting for connect to fiinsh
    public func connect(
        will: (topicName: String, payload: ByteBuffer, retain: Bool)? = nil
    ) -> EventLoopFuture<Void> {
        guard self.connection == nil else { return eventLoopGroup.next().makeFailedFuture(Error.alreadyConnected) }

        let info = MQTTConnectInfo(
            cleanSession: true,
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
                    self.closeListeners.notify(result)
                }
                return connection.sendMessage(MQTTConnectMessage(connect: info, will: publish)) { message in
                    guard message.type == .CONNACK else { throw Error.failedToConnect }
                    return true
                }
            }
            .map { _ in }
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

        let packetId = Self.globalPacketId.add(1)
        return connection.sendMessage(MQTTPublishMessage(publish: info, packetId: packetId)) { message in
            guard message.packetId == packetId else { return false }
            if info.qos == .atLeastOnce {
                guard message.type == .PUBACK else { throw Error.unexpectedMessage }
            } else if info.qos == .exactlyOnce {
                guard message.type == .PUBREC else { throw Error.unexpectedMessage }
            }
            return true
        }
        .flatMap { _ in
            if info.qos == .exactlyOnce {
                return connection.sendMessage(MQTTAckMessage(type: .PUBREL, packetId: packetId)) { message in
                    guard message.packetId == packetId else { return false }
                    guard message.type == .PUBCOMP else { throw Error.unexpectedMessage }
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
        let packetId = Self.globalPacketId.add(1)
        
        return connection.sendMessage(MQTTSubscribeMessage(subscriptions: subscriptions, packetId: packetId)) { message in
            guard message.packetId == packetId else { return false }
            guard message.type == .SUBACK else { throw Error.unexpectedMessage }
            return true
        }
        .map { _ in }
    }

    /// Unsubscribe from topic
    /// - Parameter subscriptions: Subscription infos
    /// - Returns: Future waiting for unsubscribe to complete. Will wait for UNSUBACK message from server
    public func unsubscribe(from subscriptions: [MQTTSubscribeInfo]) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
        let packetId = Self.globalPacketId.add(1)

        return connection.sendMessage(MQTTUnsubscribeMessage(subscriptions: subscriptions, packetId: packetId)) { message in
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
        
        return connection.sendMessage(MQTTPingreqMessage()) { message in
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
