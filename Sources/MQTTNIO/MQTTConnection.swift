//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2021 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

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
    let taskHandler: MQTTTaskHandler

    private init(channel: Channel, timeout: TimeAmount?, taskHandler: MQTTTaskHandler) {
        self.channel = channel
        self.timeout = timeout
        self.taskHandler = taskHandler
    }

    static func create(client: MQTTClient, pingInterval: TimeAmount) -> EventLoopFuture<MQTTConnection> {
        let taskHandler = MQTTTaskHandler(client: client)
        return self.createBootstrap(client: client, pingInterval: pingInterval, taskHandler: taskHandler)
            .map { MQTTConnection(channel: $0, timeout: client.configuration.timeout, taskHandler: taskHandler) }
    }

    static func createBootstrap(client: MQTTClient, pingInterval: TimeAmount, taskHandler: MQTTTaskHandler) -> EventLoopFuture<Channel> {
        let eventLoop = client.eventLoopGroup.next()
        let channelPromise = eventLoop.makePromise(of: Channel.self)
        do {
            // get bootstrap based off what eventloop we are running on
            let bootstrap = try getBootstrap(client: client)
            bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .connectTimeout(client.configuration.connectTimeout)
                .channelInitializer { channel in
                    // Work out what handlers to add
                    let handlers: [ChannelHandler] = [
                        MQTTMessageHandler(client, pingInterval: pingInterval),
                        taskHandler,
                    ]
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
            requestKey: Data(requestKey).base64EncodedString(),
            maxFrameSize: client.configuration.webSocketMaxFrameSize
        ) { channel, _ in
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

    func sendMessage(_ message: MQTTPacket, checkInbound: @escaping (MQTTPacket) throws -> Bool) -> EventLoopFuture<MQTTPacket> {
        let task = MQTTTask(on: channel.eventLoop, timeout: self.timeout, checkInbound: checkInbound)

        self.taskHandler.addTask(task)
            .flatMap {
                self.channel.writeAndFlush(message)
            }
            .whenFailure { error in
                task.fail(error)
            }
        return task.promise.futureResult
    }

    func updatePingreqTimeout(_ timeout: TimeAmount) {
        self.channel.pipeline.handler(type: MQTTMessageHandler.self).whenSuccess { handler in
            handler.updatePingreqTimeout(timeout)
        }
    }

    var closeFuture: EventLoopFuture<Void> { self.channel.closeFuture }
}
