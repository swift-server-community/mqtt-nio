//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2022 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1
import NIOWebSocket

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Network)
import Network
import NIOTransportServices
#endif
#if os(macOS) || os(Linux) || os(Android)
import NIOSSL
#endif

final class MQTTConnection {
    let channel: Channel
    let cleanSession: Bool
    let timeout: TimeAmount?
    let channelHandler: MQTTChannelHandler

    private init(channel: Channel, cleanSession: Bool, timeout: TimeAmount?, channelHandler: MQTTChannelHandler) {
        self.channel = channel
        self.cleanSession = cleanSession
        self.timeout = timeout
        self.channelHandler = channelHandler
    }

    static func create(client: MQTTClient, cleanSession: Bool, pingInterval: TimeAmount) -> EventLoopFuture<MQTTConnection> {
        self.createBootstrap(client: client, pingInterval: pingInterval)
            .flatMap { channel in
                channel.eventLoop.submit {
                    try channel.pipeline.syncOperations.handler(type: MQTTChannelHandler.self)
                }.map { channelHandler in
                    MQTTConnection(
                        channel: channel,
                        cleanSession: cleanSession,
                        timeout: client.configuration.timeout,
                        channelHandler: channelHandler
                    )
                }
            }
    }

    static func createBootstrap(client: MQTTClient, pingInterval: TimeAmount) -> EventLoopFuture<Channel> {
        let eventLoop = client.eventLoopGroup.next()
        let channelPromise = eventLoop.makePromise(of: Channel.self)
        do {
            // get bootstrap based off what eventloop we are running on
            let bootstrap = try getBootstrap(client: client)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .connectTimeout(client.configuration.connectTimeout)
                .channelInitializer { channel in
                    // Work out what handlers to add
                    let handlers: [ChannelHandler] = [
                        MQTTChannelHandler(
                            configuration: .init(
                                disablePing: client.configuration.disablePing,
                                pingInterval: pingInterval,
                                timeout: client.configuration.timeout,
                                version: client.configuration.version
                            ),
                            eventLoop: channel.eventLoop,
                            logger: client.logger,
                            publishListeners: client.publishListeners
                        )
                    ]
                    // are we using websockets
                    if let webSocketConfiguration = client.configuration.webSocketConfiguration {
                        // prepare for websockets and on upgrade add handlers
                        let promise = eventLoop.makePromise(of: Void.self)
                        promise.futureResult.map { _ in channel }
                            .cascade(to: channelPromise)

                        return Self.setupChannelForWebsockets(
                            client: client,
                            channel: channel,
                            webSocketConfiguration: webSocketConfiguration,
                            upgradePromise: promise
                        ) {
                            try channel.pipeline.syncOperations.addHandlers(handlers)
                        }
                    } else {
                        return channel.pipeline.addHandlers(handlers)
                    }
                }

            let channelFuture: EventLoopFuture<Channel>

            if client.port == 0 {
                channelFuture = bootstrap.connect(unixDomainSocketPath: client.host)
            } else {
                channelFuture = bootstrap.connect(host: client.host, port: client.port)
            }

            channelFuture
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
                options = try config.getNWProtocolTLSOptions(logger: client.logger)
            #if os(macOS) || os(Linux)
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

        #if os(macOS) || os(Linux) || os(Android)
        if let clientBootstrap = ClientBootstrap(validatingGroup: client.eventLoopGroup) {
            let tlsConfiguration: TLSConfiguration
            switch client.configuration.tlsConfiguration {
            case .niossl(let config):
                tlsConfiguration = config
            default:
                tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            }
            if client.configuration.useSSL {
                let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
                let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: serverName)
                bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
                return bootstrap.enableTLS()
            } else {
                bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: NIOInsecureNoTLS())
            }
            return bootstrap
        }
        #endif
        preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
    }

    static func setupChannelForWebsockets(
        client: MQTTClient,
        channel: Channel,
        webSocketConfiguration: MQTTClient.WebSocketConfiguration,
        upgradePromise promise: EventLoopPromise<Void>,
        afterHandlerAdded: @escaping () throws -> Void
    ) -> EventLoopFuture<Void> {
        // initial HTTP request handler, before upgrade
        let httpHandler = WebSocketInitialRequestHandler(
            host: client.configuration.sniServerName ?? client.hostHeader,
            urlPath: webSocketConfiguration.urlPath,
            additionalHeaders: webSocketConfiguration.initialRequestHeaders,
            upgradePromise: promise
        )
        // create random key for request key
        let requestKey = (0..<16).map { _ in UInt8.random(in: .min ..< .max) }
        let websocketUpgrader = NIOWebSocketClientUpgrader(
            requestKey: Data(requestKey).base64EncodedString(),
            maxFrameSize: client.configuration.webSocketMaxFrameSize
        ) { channel, _ in
            let future = channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(WebSocketHandler())
                try afterHandlerAdded()
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

    func sendMessageNoWait(_ message: MQTTPacket) -> EventLoopFuture<Void> {
        self.channel.writeAndFlush(message)
    }

    func close() -> EventLoopFuture<Void> {
        if self.channel.isActive {
            return self.channel.close()
        } else {
            return self.channel.eventLoop.makeSucceededFuture(())
        }
    }

    func sendMessage(_ message: MQTTPacket, checkInbound: @escaping (MQTTPacket) throws -> Bool) -> EventLoopFuture<MQTTPacket> {
        if self.channel.eventLoop.inEventLoop {
            self.channelHandler.sendMessage(message, checkInbound: checkInbound)
        } else {
            self.channel.eventLoop.submit {
                self.channelHandler.sendMessage(message, checkInbound: checkInbound)
            }.flatMap { $0 }
        }
    }

    func updatePingreqTimeout(_ timeout: TimeAmount) {
        self.channel.pipeline.handler(type: MQTTChannelHandler.self).whenSuccess { handler in
            handler.updatePingreqTimeout(timeout)
        }
    }

    var closeFuture: EventLoopFuture<Void> { self.channel.closeFuture }
}
