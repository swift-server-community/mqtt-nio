//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import Logging
import NIOCore
import NIOPosix
import NIOQUIC
import NIOQUICHelpers

extension MQTTConnection {
    @available(iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func _makeQUICConnection(
        address: MQTTServerAddress,
        configuration: MQTTConnectionConfiguration,
        session: MQTTSessionStorage,
        eventLoop: any EventLoop,
        logger: Logger
    ) async throws -> MQTTConnection {
        guard case .quic(let verificationConfiguration, let serverName) = configuration.transport.base else {
            fatalError("Invalid configuration for QUIC connection")  // TODO: handle gracefully
        }

        let bootstrap = DatagramBootstrap(group: eventLoop).channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        @Sendable func _channelInitializer(_ channel: any Channel) -> EventLoopFuture<(any Channel, QUICHandler.ConnectionMultiplexer<Never>)> {
            channel.eventLoop.makeCompletedFuture {
                let quicConfiguration = QUICConfiguration.client(
                    verificationConfiguration: verificationConfiguration,
                    applicationProtocols: ["mqtt"]
                )
                let (quicHandler, connectionMultiplexer) = try QUICHandler.makeHandlerAndConnectionMultiplexer(
                    channel: channel,
                    quicConfiguration: quicConfiguration,
                    logger: logger,
                    metrics: nil,
                    inboundStreamChannelInitializer: { channel -> EventLoopFuture<Never> in
                        channel.eventLoop.makeCompletedFuture { fatalError() }
                    }
                )
                try channel.pipeline.syncOperations.addHandler(quicHandler)
                return (channel, connectionMultiplexer)
            }
        }

        let (channel, clientConnectionMultiplexer) =
            switch address.value {
            case .hostname(let host, let port):
                try await bootstrap.connect(host: host, port: port, channelInitializer: _channelInitializer)
            case .unixDomainSocket(let path):
                try await bootstrap.connect(unixDomainSocketPath: path, channelInitializer: _channelInitializer)
            }

        let connection = try await clientConnectionMultiplexer.createNewConnection(
            serverName: serverName,
            remoteAddress: channel.remoteAddress!,  // TODO: handle gracefully
        ) { _ -> EventLoopFuture<Never> in
            fatalError()  // No inbound streams expected.
        }

        logger.info("Client created QUIC connection")

        return try await connection.createBidirectionalStream { streamInitializer in
            streamInitializer.channel.eventLoop.makeCompletedFuture {
                let handler = try self._setupChannel(
                    streamInitializer.channel,
                    configuration: configuration,
                    session: session,
                    logger: logger
                )
                return MQTTConnection(
                    channel: streamInitializer.channel,
                    channelHandler: handler,
                    configuration: configuration,
                    address: address,
                    logger: logger
                )
            }
        }
    }
}
