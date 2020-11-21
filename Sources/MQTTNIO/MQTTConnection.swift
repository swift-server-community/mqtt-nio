import Foundation
#if canImport(Network)
import Network
#endif
import NIO
import NIOHTTP1
import NIOSSL
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
        return createBootstrap(client: client, pingInterval: pingInterval)
            .map { MQTTConnection(channel: $0, timeout: client.configuration.timeout)}
    }
    
    static func createBootstrap(client: MQTTClient, pingInterval: TimeAmount) -> EventLoopFuture<Channel> {
        let eventLoop = client.eventLoopGroup.next()
        let channelPromise = eventLoop.makePromise(of: Channel.self)
        do {
            // Work out what handlers to add
            var handlers: [ChannelHandler] = [
                MQTTEncodeHandler(logger: client.logger),
                ByteToMessageHandler(ByteToMQTTMessageDecoder(client: client))
            ]
            if !client.configuration.disablePing {
                handlers = [PingreqHandler(client: client, timeout: pingInterval)] + handlers
            }
            // get bootstrap based off what eventloop we are running on
            let bootstrap = try getBootstrap(client: client)
            bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .channelInitializer { channel in
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
        #if canImport(Network)
        // if eventLoop is compatible with NIOTransportServices create a NIOTSConnectionBootstrap
        if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *),
           let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: client.eventLoopGroup) {
            // create NIOClientTCPBootstrap with NIOTS TLS provider
            let tlsConfiguration = client.configuration.tlsConfiguration
            let parameters = try tlsConfiguration.getNWProtocolTLSOptions()
            let tlsProvider = NIOTSClientTLSProvider(tlsOptions: parameters)
            bootstrap = NIOClientTCPBootstrap(tsBootstrap, tls: tlsProvider)
        } else if let clientBootstrap = ClientBootstrap(validatingGroup: client.eventLoopGroup) {
            let tlsConfiguration = client.configuration.tlsConfiguration
            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: client.host)
            bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
        } else {
            preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
        }
        #else
        if let clientBootstrap = ClientBootstrap(validatingGroup: client.eventLoopGroup) {
            let tlsConfiguration = client.configuration.tlsConfiguration ?? TLSConfiguration.forClient()
            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: client.host)
            bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
        } else {
            preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
        }
        #endif
        if client.configuration.useSSL {
            return bootstrap.enableTLS()
        }
        return bootstrap
    }

    static func setupChannelForWebsockets(
        client: MQTTClient,
        channel: Channel,
        upgradePromise promise: EventLoopPromise<Void>,
        afterHandlerAdded: @escaping () -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        // initial HTTP request handler, before upgrade
        let httpHandler = WebSocketInitialRequestHandler(
            host: client.host,
            urlPath: client.configuration.webSocketURLPath ?? "/",
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

    func sendMessageNoWait(_ message: MQTTOutboundMessage) -> EventLoopFuture<Void> {
        return channel.writeAndFlush(message)
    }
    
    func close() -> EventLoopFuture<Void> {
        if channel.isActive {
            return channel.close()
        } else {
            return channel.eventLoop.makeSucceededFuture(())
        }
    }
    
    var closeFuture: EventLoopFuture<Void> { channel.closeFuture }
}

