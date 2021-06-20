import Foundation
#if canImport(Network)
import Network
#endif
import NIO
import NIOHTTP1
#if canImport(NIOSSL)
import NIOSSL
#endif
import NIOTransportServices
import NIOWebSocket

final class MQTTConnection {
    let channel: Channel
    let timeout: TimeAmount?

    private init(channel: Channel, timeout: TimeAmount?) {
        self.channel = channel
        self.timeout = timeout
    }

    static func create(client: MQTTClient, pingInterval: TimeAmount) -> EventLoopFuture<MQTTConnection> {
        return self.createBootstrap(client: client, pingInterval: pingInterval)
            .map { MQTTConnection(channel: $0, timeout: client.configuration.timeout) }
    }

    static func createBootstrap(client: MQTTClient, pingInterval: TimeAmount) -> EventLoopFuture<Channel> {
        let eventLoop = client.eventLoopGroup.next()
        let channelPromise = eventLoop.makePromise(of: Channel.self)
        do {
            // get bootstrap based off what eventloop we are running on
            let bootstrap = try getBootstrap(client: client)
            bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    // Work out what handlers to add
                    var handlers: [ChannelHandler] = [
                        MQTTEncodeHandler(client: client),
                        ByteToMessageHandler(ByteToMQTTMessageDecoder(client: client)),
                    ]
                    if !client.configuration.disablePing {
                        handlers = [PingreqHandler(client: client, timeout: pingInterval)] + handlers
                    }
                    // are we using websockets
                    if client.configuration.useWebSockets {
                        // prepare for websockets and on upgrade add handlers
                        let promise = eventLoop.makePromise(of: Void.self)
                        promise.futureResult.map { _ in channel }
                            .cascade(to: channelPromise)

                        return Self.setupChannelForWebsockets(client: client, channel: channel, upgradePromise: promise) {
                            return channel.pipeline.addHandlers(handlers)
                        }
                    } else {
                        return channel.pipeline.addHandlers(handlers)
                    }
                }
                .connect(host: client.host, port: client.port)
                .map { channel in
                    if !client.configuration.useWebSockets {
                        channelPromise.succeed(channel)
                    }
                }
                .cascadeFailure(to: channelPromise)
        } catch {
            channelPromise.fail(error)
        }
        return channelPromise.futureResult
    }

    static func getBootstrap(client: MQTTClient) throws -> NIOClientTCPBootstrap {
        var bootstrap: NIOClientTCPBootstrap
        let serverName = client.configuration.sniServerName ?? client.host
        #if canImport(Network)
        // if eventLoop is compatible with NIOTransportServices create a NIOTSConnectionBootstrap
        if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *),
           let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: client.eventLoopGroup)
        {
            // create NIOClientTCPBootstrap with NIOTS TLS provider
            let options: NWProtocolTLS.Options
            switch client.configuration.tlsConfiguration {
            case .ts(let config):
                options = try config.getNWProtocolTLSOptions()
            #if canImport(NIOSSL)
            case .niossl:
                throw MQTTError.wrongTLSConfig
            #endif
            default:
                options = NWProtocolTLS.Options()
            }
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, serverName)
            let tlsProvider = NIOTSClientTLSProvider(tlsOptions: options)
            bootstrap = NIOClientTCPBootstrap(tsBootstrap, tls: tlsProvider)
            if client.configuration.useSSL {
                return bootstrap.enableTLS()
            }
            return bootstrap
        }
        #endif
        #if canImport(NIOSSL) // canImport(Network)
        if let clientBootstrap = ClientBootstrap(validatingGroup: client.eventLoopGroup) {
            let tlsConfiguration: TLSConfiguration
            switch client.configuration.tlsConfiguration {
            case .niossl(let config):
                tlsConfiguration = config
            default:
                tlsConfiguration = TLSConfiguration.forClient()
            }
            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: serverName)
            bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
            if client.configuration.useSSL {
                return bootstrap.enableTLS()
            }
            return bootstrap
        }
        #endif
        preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
    }

    static func setupChannelForWebsockets(
        client: MQTTClient,
        channel: Channel,
        upgradePromise promise: EventLoopPromise<Void>,
        afterHandlerAdded: @escaping () -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        // initial HTTP request handler, before upgrade
        let httpHandler = WebSocketInitialRequestHandler(
            host: client.configuration.sniServerName ?? client.hostHeader,
            urlPath: client.configuration.webSocketURLPath ?? "/mqtt",
            upgradePromise: promise
        )
        // create random key for request key
        let requestKey = (0..<16).map { _ in UInt8.random(in: .min ..< .max) }
        let websocketUpgrader = NIOWebSocketClientUpgrader(
            requestKey: Data(requestKey).base64EncodedString()) { channel, _ in
            let future = channel.pipeline.addHandler(WebSocketHandler())
                .flatMap { _ in
                    afterHandlerAdded()
                }
            future.cascade(to: promise)
            return future
        }

        let config: NIOHTTPClientUpgradeConfiguration = (
            upgraders: [websocketUpgrader],
            completionHandler: { _ in
                channel.pipeline.removeHandler(httpHandler, promise: nil)
            }
        )

        // add HTTP handler with web socket upgrade
        return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
            channel.pipeline.addHandler(httpHandler)
        }
    }

    func sendMessageWithRetry(_ message: MQTTPacket, maxRetryAttempts: Int, checkInbound: @escaping (MQTTPacket) throws -> Bool) -> EventLoopFuture<MQTTPacket> {
        let promise = self.channel.eventLoop.makePromise(of: MQTTPacket.self)

        func _sendMessage(_ message: MQTTPacket, attempt: Int) {
            self.sendMessage(message, checkInbound: checkInbound)
                .map { response in
                    promise.succeed(response)
                }
                .flatMapErrorThrowing { error in
                    switch error {
                    case MQTTError.timeout:
                        guard attempt < maxRetryAttempts else { throw MQTTError.timeout }
                        // if we have a publish message we have to resend it with `dup` set to true
                        if let publishMessage = message as? MQTTPublishPacket {
                            let publish = publishMessage.publish
                            let newMessage = MQTTPublishPacket(
                                publish: .init(qos: publish.qos, retain: publish.retain, dup: true, topicName: publish.topicName, payload: publish.payload),
                                packetId: publishMessage.packetId
                            )
                            _sendMessage(newMessage, attempt: attempt + 1)
                        } else {
                            _sendMessage(message, attempt: attempt + 1)
                        }
                    default:
                        throw error
                    }
                }
                .cascadeFailure(to: promise)
        }
        _sendMessage(message, attempt: 0)
        return promise.futureResult
    }

    func sendMessageNoWait(_ message: MQTTPacket) -> EventLoopFuture<Void> {
        return self.channel.writeAndFlush(message)
    }

    func close() -> EventLoopFuture<Void> {
        if self.channel.isActive {
            return self.channel.close()
        } else {
            return self.channel.eventLoop.makeSucceededFuture(())
        }
    }

    private func sendMessage(_ message: MQTTPacket, checkInbound: @escaping (MQTTPacket) throws -> Bool) -> EventLoopFuture<MQTTPacket> {
        let task = MQTTTask(on: channel.eventLoop, timeout: self.timeout, checkInbound: checkInbound)
        let taskHandler = MQTTTaskHandler(task: task, channel: channel)

        channel.pipeline.addHandler(taskHandler)
            .flatMap {
                self.channel.writeAndFlush(message)
            }
            .whenFailure { error in
                task.fail(error)
            }
        return task.promise.futureResult
    }

    var closeFuture: EventLoopFuture<Void> { self.channel.closeFuture }
}
