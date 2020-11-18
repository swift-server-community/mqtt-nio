import Foundation
#if canImport(Network)
import Network
#endif
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL
import NIOTransportServices
import NIOWebSocket

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
    /// Client configuration
    let configuration: Configuration
    /// Called whenever a publish event occurs
    let publishCallback: (Result<MQTTPublishInfo, Swift.Error>) -> ()

    /// Channel client is running on
    var channel: Channel?
    /// Identifier for client (extracted from connect info)
    var clientIdentifier = ""

    private static let globalPacketId = NIOAtomic<UInt16>.makeAtomic(value: 1)

    /// Configuration for MQTTClient
    public struct Configuration {
        public init(
            disablePingreq: Bool = false,
            pingreqInterval: TimeAmount? = nil,
            timeout: TimeAmount? = nil,
            useSSL: Bool = false,
            useWebSockets: Bool = false,
            tlsConfiguration: TLSConfiguration? = nil,
            webSocketURLPath: String? = nil
        ) {
            self.disablePingreq = disablePingreq
            self.pingreqInterval = pingreqInterval
            self.timeout = timeout
            self.useSSL = useSSL
            self.useWebSockets = useWebSockets
            self.tlsConfiguration = tlsConfiguration
            self.webSocketURLPath = webSocketURLPath
        }

        /// disable the sending of pingreq messages
        let disablePingreq: Bool
        /// override internal between each pingreq message
        let pingreqInterval: TimeAmount?
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
        self.channel = nil
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
        try channel?.close().wait()
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
        guard self.channel == nil else { return eventLoopGroup.next().makeFailedFuture(Error.alreadyConnected) }
        // work out pingreq interval
        let pingreqInterval = configuration.pingreqInterval ?? TimeAmount.seconds(max(Int64(info.keepAliveSeconds - 5), 5))

        return createBootstrap(pingreqInterval: pingreqInterval)
            .flatMap { _ -> EventLoopFuture<MQTTInboundMessage> in
                self.clientIdentifier = info.clientIdentifier
                return self.sendMessage(MQTTConnectMessage(connect: info, will: nil)) { message in
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
        if info.qos == .atMostOnce {
            // don't send a packet id if QOS is at most once. (MQTT-2.3.1-5)
            return sendMessageNoWait(MQTTPublishMessage(publish: info, packetId: 0))
        }

        let packetId = Self.globalPacketId.add(1)
        return sendMessage(MQTTPublishMessage(publish: info, packetId: packetId)) { message in
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
                return self.sendMessage(MQTTAckMessage(type: .PUBREL, packetId: packetId)) { message in
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
        let packetId = Self.globalPacketId.add(1)
        return sendMessage(MQTTSubscribeMessage(subscriptions: infos, packetId: packetId)) { message in
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
        let packetId = Self.globalPacketId.add(1)
        return sendMessage(MQTTUnsubscribeMessage(subscriptions: infos, packetId: packetId)) { message in
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
    /// - Parameter infos: Subscription infos
    /// - Returns: Future waiting for unsubscribe to complete. Will wait for UNSUBACK message from server
    public func pingreq() -> EventLoopFuture<Void> {
        return sendMessage(MQTTPingreqMessage()) { message in
            guard message.type == .PINGRESP else { return false }
            return true
        }
        .map { _ in }
    }

    /// Disconnect from server
    /// - Returns: Future waiting on disconnect message to be sent
    public func disconnect() -> EventLoopFuture<Void> {
        let disconnect: EventLoopFuture<Void> = sendMessageNoWait(MQTTDisconnectMessage())
            .flatMap {
                let future = self.channel!.close()
                self.channel = nil
                return future
            }
        return disconnect
    }
}

extension MQTTClient {

    func getBootstrap(_ eventLoopGroup: EventLoopGroup) throws -> NIOClientTCPBootstrap {
        var bootstrap: NIOClientTCPBootstrap
        #if canImport(Network)
        // if eventLoop is compatible with NIOTransportServices create a NIOTSConnectionBootstrap
        if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *),
           let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoopGroup) {
            // create NIOClientTCPBootstrap with NIOTS TLS provider
            //let tlsConfiguration = self.tlsConfiguration ?? TLSConfiguration.forClient()
            let parameters = NWProtocolTLS.Options()//tlsConfiguration.getNWProtocolTLSOptions()
            let tlsProvider = NIOTSClientTLSProvider(tlsOptions: parameters)
            bootstrap = NIOClientTCPBootstrap(tsBootstrap, tls: tlsProvider)
        } else if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoopGroup) {
            let tlsConfiguration = self.configuration.tlsConfiguration ?? TLSConfiguration.forClient()
            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: host)
            bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
        } else {
            preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
        }
        #else
        if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoopGroup) {
            let tlsConfiguration = self.tlsConfiguration ?? TLSConfiguration.forClient()
            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: host)
            bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
        } else {
            preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
        }
        #endif
        if configuration.useSSL {
            return bootstrap.enableTLS()
        }
        return bootstrap
    }

    func createBootstrap(pingreqInterval: TimeAmount) -> EventLoopFuture<Void> {
        let promise = self.eventLoopGroup.next().makePromise(of: Void.self)
        do {
            // Work out what handlers to add
            var handlers: [ChannelHandler] = [
                MQTTEncodeHandler(client: self),
                ByteToMessageHandler(ByteToMQTTMessageDecoder(client: self))
            ]
            if !configuration.disablePingreq {
                handlers = [PingreqHandler(client: self, timeout: pingreqInterval)] + handlers
            }
            // get bootstrap based off what eventloop we are running on
            let bootstrap = try getBootstrap(self.eventLoopGroup)
            bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    // are we using websockets
                    if self.configuration.useWebSockets {
                        // prepare for websockets and on upgrade add handlers
                        return self.setupChannelForWebsockets(channel: channel, upgradePromise: promise) {
                            return channel.pipeline.addHandlers(handlers)
                        }
                    } else {
                        return channel.pipeline.addHandlers(handlers)
                    }
                }
                .connect(host: self.host, port: self.port)
                .map { channel in
                    self.channel = channel
                    channel.closeFuture.whenComplete { _ in
                        self.channel = nil
                    }
                }
                .map {
                    if !self.configuration.useWebSockets {
                        promise.succeed(())
                    }
                }
                .cascadeFailure(to: promise)
        } catch {
            promise.fail(error)
        }
        return promise.futureResult
    }

    func setupChannelForWebsockets(
        channel: Channel,
        upgradePromise promise: EventLoopPromise<Void>,
        afterHandlerAdded: @escaping () -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        // initial HTTP request handler, before upgrade
        let httpHandler = WebSocketInitialRequestHandler(
            host: self.host,
            urlPath: configuration.webSocketURLPath ?? "/",
            upgradePromise: promise
        )
        // create random key for request key
        let requestKey = (0..<16).map { _ in UInt8.random(in: .min ..< .max)}
        let websocketUpgrader = NIOWebSocketClientUpgrader(
            requestKey: Data(requestKey).base64EncodedString()) { channel, req in
            let future = channel.pipeline.addHandler(WebSocketHandler())
                .flatMap { _ in
                    afterHandlerAdded()
                }
            future.cascade(to: promise)
            return future
        }

        let config: NIOHTTPClientUpgradeConfiguration = (
            upgraders: [ websocketUpgrader ],
            completionHandler: { _ in
                channel.pipeline.removeHandler(httpHandler, promise: nil)
        })

        // add HTTP handler with web socket upgrade
        return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
            channel.pipeline.addHandler(httpHandler)
        }

    }

    func sendMessage(_ message: MQTTOutboundMessage, checkInbound: @escaping (MQTTInboundMessage) throws -> Bool) -> EventLoopFuture<MQTTInboundMessage> {
        guard let channel = self.channel else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
        let task = MQTTTask(on: eventLoopGroup.next(), timeout: configuration.timeout, checkInbound: checkInbound)
        let taskHandler = MQTTTaskHandler(task: task, channel: channel)

        channel.pipeline.addHandler(taskHandler)
            .flatMap {
                channel.writeAndFlush(message)
            }
            .whenFailure { error in
                task.fail(error)
            }
        return task.promise.futureResult
    }

    func sendMessageNoWait(_ message: MQTTOutboundMessage) -> EventLoopFuture<Void> {
        guard let channel = self.channel else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
        return channel.writeAndFlush(message)
    }
}
