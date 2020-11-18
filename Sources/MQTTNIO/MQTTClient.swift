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
public class MQTTClient {
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
    /// logger
    var logger: Logger
    /// Client configuration
    let configuration: Configuration
    /// Called whenever a publish event occurs
    let publishCallback: (Result<MQTTPublishInfo, Swift.Error>) -> ()

    /// Connection client is using
    var connection: MQTTConnection?

    private static let globalPacketId = NIOAtomic<UInt16>.makeAtomic(value: 1)
    /// default logger that logs nothing
    private static let loggingDisabled = Logger(label: "MQTT-do-not-log", factory: { _ in SwiftLogNoOpLogHandler() })

    /// Configuration for MQTTClient
    public struct Configuration {
        public init(
            disablePing: Bool = false,
            pingInterval: TimeAmount? = nil,
            timeout: TimeAmount? = nil,
            useSSL: Bool = false,
            useWebSockets: Bool = false,
            tlsConfiguration: TLSConfiguration? = nil,
            webSocketURLPath: String? = nil
        ) {
            self.disablePing = disablePing
            self.pingInterval = pingInterval
            self.timeout = timeout
            self.useSSL = useSSL
            self.useWebSockets = useWebSockets
            self.tlsConfiguration = tlsConfiguration
            self.webSocketURLPath = webSocketURLPath
        }

        /// disable the sending of pingreq messages
        let disablePing: Bool
        /// override interval between each pingreq message
        let pingInterval: TimeAmount?
        /// timeout for server response
        let timeout: TimeAmount?
        /// use encrypted connection to server
        let useSSL: Bool
        /// use a websocket connection to server
        let useWebSockets: Bool
        /// TLS configuration
        let tlsConfiguration: TLSConfiguration?
        /// URL Path for web socket. Defaults to "/"
        let webSocketURLPath: String?
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
        eventLoopGroupProvider: NIOEventLoopGroupProvider,
        logger: Logger? = nil,
        configuration: Configuration = Configuration(),
        publishCallback: @escaping (Result<MQTTPublishInfo, Swift.Error>) -> () = { _ in }
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
        self.configuration = configuration
        self.publishCallback = publishCallback
        self.connection = nil
        self.logger = logger ?? Self.loggingDisabled
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch eventLoopGroupProvider {
        case .createNew:
            #if canImport(Network)
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), configuration.tlsConfiguration == nil {
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
    ///   - info: Connection info
    ///   - will: Publish message to be posted as soon as connection is made
    /// - Returns: Future waiting for connect to fiinsh
    public func connect(info: MQTTConnectInfo, will: MQTTPublishInfo? = nil) -> EventLoopFuture<Void> {
        guard self.connection == nil else { return eventLoopGroup.next().makeFailedFuture(Error.alreadyConnected) }
        // work out pingreq interval
        let pingInterval = configuration.pingInterval ?? TimeAmount.seconds(max(Int64(info.keepAliveSeconds - 5), 5))

        return MQTTConnection.create(client: self, pingInterval: pingInterval)
            .flatMap { connection -> EventLoopFuture<MQTTInboundMessage> in
                self.connection = connection
                connection.closeFuture.whenComplete { _ in
                    self.connection = nil
                }
                // attach client identifier to logger
                self.logger = self.logger.attachingClientIdentifier(info.clientIdentifier)
                return connection.sendMessage(MQTTConnectMessage(connect: info, will: nil)) { message in
                    guard message.type == .CONNACK else { throw Error.failedToConnect }
                    return true
                }
            }
            .map { _ in }
    }

    /// Publish message to topic
    /// - Parameter info: Publish info
    /// - Returns: Future waiting for publish to complete. Depending on QoS setting the future will complete
    ///     when message is sent, when PUBACK is received or when PUBREC and following PUBCOMP are
    ///     received
    public func publish(info: MQTTPublishInfo) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
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
    /// - Parameter infos: Subscription infos
    /// - Returns: Future waiting for subscribe to complete. Will wait for SUBACK message from server
    public func subscribe(infos: [MQTTSubscribeInfo]) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
        let packetId = Self.globalPacketId.add(1)
        
        return connection.sendMessage(MQTTSubscribeMessage(subscriptions: infos, packetId: packetId)) { message in
            guard message.packetId == packetId else { return false }
            guard message.type == .SUBACK else { throw Error.unexpectedMessage }
            return true
        }
        .map { _ in }
    }

    /// Unsubscribe from topic
    /// - Parameter infos: Subscription infos
    /// - Returns: Future waiting for unsubscribe to complete. Will wait for UNSUBACK message from server
    public func unsubscribe(infos: [MQTTSubscribeInfo]) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
        let packetId = Self.globalPacketId.add(1)

        return connection.sendMessage(MQTTUnsubscribeMessage(subscriptions: infos, packetId: packetId)) { message in
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
}

extension Logger {
    func attachingClientIdentifier(_ identifier: String?) -> Logger {
        var logger = self
        logger[metadataKey: "mqtt-client"] = identifier.map { .string($0) }
        return logger
    }
}
