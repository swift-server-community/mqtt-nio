#if canImport(Network)
import Network
#endif
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL
import NIOTransportServices
import NIOWebSocket

public class MQTTClient {
    enum Error: Swift.Error {
        case alreadyConnected
        case failedToConnect
        case noConnection
        case unexpectedMessage
        case decodeError
    }
    let eventLoopGroup: EventLoopGroup
    let eventLoopGroupProvider: NIOEventLoopGroupProvider
    let host: String
    let port: Int
    let publishCallback: (Result<MQTTPublishInfo, Swift.Error>) -> ()
    let tlsConfiguration: TLSConfiguration?
    var channel: Channel?
    var clientIdentifier = ""

    static let globalPacketId = NIOAtomic<UInt16>.makeAtomic(value: 1)

    public init(
        host: String,
        port: Int? = nil,
        tlsConfiguration: TLSConfiguration? = nil,
        eventLoopGroupProvider: NIOEventLoopGroupProvider,
        publishCallback: @escaping (Result<MQTTPublishInfo, Swift.Error>) -> () = { _ in }
    ) throws {
        self.host = host
        if let port = port {
            self.port = port
        } else {
            if tlsConfiguration != nil {
                self.port = 8883
            } else {
                self.port = 1883
            }
        }
        self.tlsConfiguration = tlsConfiguration
        self.publishCallback = publishCallback
        self.channel = nil
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch eventLoopGroupProvider {
        case .createNew:
            #if canImport(Network)
                if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
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

    public func syncShutdownGracefully() throws {
        try channel?.close().wait()
        switch self.eventLoopGroupProvider {
        case .createNew:
            try eventLoopGroup.syncShutdownGracefully()
        case .shared:
            break
        }
    }

    public func connect(info: MQTTConnectInfo, will: MQTTPublishInfo? = nil) -> EventLoopFuture<Void> {
        guard self.channel == nil else { return eventLoopGroup.next().makeFailedFuture(Error.alreadyConnected) }
        let timeout = TimeAmount.seconds(max(Int64(info.keepAliveSeconds - 5), 5))
        return createBootstrap(pingreqTimeout: timeout)
            .flatMap { channel -> EventLoopFuture<MQTTInboundMessage> in
                self.clientIdentifier = info.clientIdentifier
                print(channel.pipeline)
                return self.sendMessage(MQTTConnectMessage(connect: info, will: nil)) { message in
                    guard message.type == .CONNACK else { throw Error.failedToConnect }
                    return true
                }
            }
            .map { _ in }
    }

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

    public func subscribe(infos: [MQTTSubscribeInfo]) -> EventLoopFuture<Void> {
        let packetId = Self.globalPacketId.add(1)
        return sendMessage(MQTTSubscribeMessage(subscriptions: infos, packetId: packetId)) { message in
            guard message.packetId == packetId else { return false }
            guard message.type == .SUBACK else { throw Error.unexpectedMessage }
            return true
        }
        .map { _ in }
    }

    public func unsubscribe(infos: [MQTTSubscribeInfo]) -> EventLoopFuture<Void> {
        let packetId = Self.globalPacketId.add(1)
        return sendMessage(MQTTUnsubscribeMessage(subscriptions: infos, packetId: packetId)) { message in
            guard message.packetId == packetId else { return false }
            guard message.type == .UNSUBACK else { throw Error.unexpectedMessage }
            return true
        }
        .map { _ in }
    }

    public func pingreq() -> EventLoopFuture<Void> {
        return sendMessage(MQTTPingreqMessage()) { message in
            guard message.type == .PINGRESP else { return false }
            return true
        }
        .map { _ in }
    }

    public func disconnect() -> EventLoopFuture<Void> {
        let disconnect: EventLoopFuture<Void> = sendMessageNoWait(MQTTDisconnectMessage())
            .flatMap {
                let future = self.channel!.close()
                self.channel = nil
                return future
            }
        return disconnect
    }

    public func read() throws {
        guard let channel = self.channel else { throw Error.noConnection }
        return channel.read()
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
            let tlsConfiguration = self.tlsConfiguration ?? TLSConfiguration.forClient()
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
        if tlsConfiguration != nil {
            return bootstrap.enableTLS()
        }
        return bootstrap
    }

    func createBootstrap(pingreqTimeout: TimeAmount) -> EventLoopFuture<Channel> {
        do {
            let bootstrap = try getBootstrap(self.eventLoopGroup)
            return bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    let httpHandler = HTTPInitialRequestHandler(host: self.host)

                    let websocketUpgrader = NIOWebSocketClientUpgrader(
                        requestKey: "OfS0wDaT5NoxF2gqm7Zj2YtetzM=") { channel, req in
                        let future: EventLoopFuture<Void> = channel.pipeline.addHandler(WebSocketPingPongHandler())
                            .flatMap { _ in
                                channel.pipeline.addHandlers(self.getSSLHandler() + [
                                    PingreqHandler(client: self, timeout: pingreqTimeout),
                                    MQTTEncodeHandler(client: self),
                                    ByteToMessageHandler(ByteToMQTTMessageDecoder(client: self))
                                ])
                            }
                            .map { _ in
                                print(self.channel!.pipeline)
                            }
                        future.cascade(to: promise)
                        return future
                    }

                    let config: NIOHTTPClientUpgradeConfiguration = (
                        upgraders: [ websocketUpgrader ],
                        completionHandler: { _ in
                            channel.pipeline.removeHandler(httpHandler, promise: nil)
                    })

                    return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
                        channel.pipeline.addHandler(httpHandler)
                    }
                }
                .connect(host: self.host, port: self.port)
                .map { channel in
                    self.channel = channel
                    channel.closeFuture.whenComplete { _ in
                        self.channel = nil
                    }
                    return channel
                }
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    func sendMessage(_ message: MQTTOutboundMessage, checkInbound: @escaping (MQTTInboundMessage) throws -> Bool) -> EventLoopFuture<MQTTInboundMessage> {
        guard let channel = self.channel else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
        let task = MQTTTask(on: eventLoopGroup.next(), checkInbound: checkInbound)
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
