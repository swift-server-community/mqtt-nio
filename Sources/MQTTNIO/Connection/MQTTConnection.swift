//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2025 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIO
import NIOHTTP1
import NIOWebSocket
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Network)
import Network
import NIOTransportServices
#endif
#if os(macOS) || os(Linux)
import NIOSSL
#endif

/// A single connection to an MQTT server.
public final actor MQTTConnection: Sendable {
    nonisolated public let unownedExecutor: UnownedSerialExecutor

    /// Client identifier for the MQTT server.
    public private(set) var identifier: String
    /// Logger used by connection
    let logger: Logger
    let channel: any Channel
    let channelHandler: MQTTChannelHandler
    let configuration: MQTTConnectionConfiguration
    let globalPacketId = Atomic<UInt16>(1)
    /// Inflight messages
    private var inflight: MQTTInflight
    let isClosed: Atomic<Bool>

    var connectionParameters = ConnectionParameters()
    let cleanSession: Bool

    /// Initialize connection
    private init(
        channel: any Channel,
        channelHandler: MQTTChannelHandler,
        configuration: MQTTConnectionConfiguration,
        cleanSession: Bool,
        identifier: String,
        address: MQTTServerAddress?,
        logger: Logger
    ) {
        self.unownedExecutor = channel.eventLoop.executor.asUnownedSerialExecutor()
        self.channel = channel
        self.channelHandler = channelHandler
        self.configuration = configuration
        self.cleanSession = cleanSession
        self.identifier = identifier
        self.logger = logger
        self.inflight = .init()
        self.isClosed = .init(false)
    }

    /// Connect to MQTT server and run operations using the connection and then close it.
    ///
    /// - Parameters:
    ///   - address: Internet address of the MQTT server.
    ///   - configuration: Configuration of the MQTT connection.
    ///   - identifier: Client identifier for the server. This must be unique.
    ///   - cleanSession: Whether to start a clean session.
    ///   - eventLoop: EventLoop to run the connection on.
    ///   - logger: Logger to use for the connection.
    ///   - isolation: Actor isolation.
    ///   - operation: Closure handling the MQTT connection.
    /// - Returns: Value returned from the operation closure.
    public static func withConnection<Value>(
        address: MQTTServerAddress,
        configuration: MQTTConnectionConfiguration = .init(),
        identifier: String,
        cleanSession: Bool = true,
        eventLoop: any EventLoop = MultiThreadedEventLoopGroup.singleton.any(),
        logger: Logger,
        isolation: isolated (any Actor)? = #isolation,
        operation: (MQTTConnection) async throws -> sending Value
    ) async throws -> sending Value {
        let connection = try await self.connect(
            address: address,
            identifier: identifier,
            cleanSession: cleanSession,
            configuration: configuration,
            eventLoop: eventLoop,
            logger: logger
        )
        do {
            let result = try await operation(connection)
            try await connection.close()
            return result
        } catch {
            try? await connection.close()
            throw error
        }
    }

    /// Publish message to topic.
    ///
    /// - Parameters:
    ///     - topicName: Topic name on which the message is published.
    ///     - payload: Message payload.
    ///     - qos: Quality of Service for message.
    ///     - retain: Whether this is a retained message.
    ///     - properties: MQTT v5 properties for the `PUBLISH` message.
    public func publish(
        to topicName: String,
        payload: ByteBuffer,
        qos: MQTTQoS,
        retain: Bool = false,
        properties: MQTTProperties = .init()
    ) async throws {
        let info = MQTTPublishInfo(qos: qos, retain: retain, dup: false, topicName: topicName, payload: payload, properties: properties)
        let packetId = self.updatePacketId()
        let packet = MQTTPublishPacket(publish: info, packetId: packetId)
        _ = try await self.publish(packet: packet)
    }

    /// Ping the server to test if it is still alive and to tell it you are alive.
    ///
    /// You shouldn't need to call this as the ``MQTTConnection`` automatically sends `PINGREQ` messages to the server to ensure the connection is still live.
    /// If you initialize the client with the configuration ``MQTTConnectionConfiguration/disablePing`` to `true`
    /// then these are disabled and it is up to you to send the `PINGREQ` messages yourself.
    public func ping() async throws {
        _ = try await self.sendMessage(MQTTPingreqPacket()) { message in
            guard message.type == .PINGRESP else { return false }
            return true
        }
    }

    private static func connect(
        address: MQTTServerAddress,
        identifier: String,
        cleanSession: Bool,
        configuration: MQTTConnectionConfiguration,
        eventLoop: any EventLoop = MultiThreadedEventLoopGroup.singleton.any(),
        logger: Logger
    ) async throws -> MQTTConnection {
        let publish =
            switch configuration.versionConfiguration {
            case .v3_1_1(let will):
                will.map {
                    MQTTPublishInfo(
                        qos: .atMostOnce,
                        retain: $0.retain,
                        dup: false,
                        topicName: $0.topicName,
                        payload: $0.payload,
                        properties: .init()
                    )
                }
            case .v5_0(_, _, let will, _):
                will.map {
                    MQTTPublishInfo(
                        qos: .atMostOnce,
                        retain: $0.retain,
                        dup: false,
                        topicName: $0.topicName,
                        payload: $0.payload,
                        properties: $0.properties
                    )
                }
            }
        let properties: MQTTProperties =
            switch configuration.versionConfiguration {
            case .v3_1_1:
                .init()
            case .v5_0(let connectProperties, _, _, _):
                connectProperties  // TODO: Do we need to set `.sessionExpiryInterval(0xFFFF_FFFF)` by default?
            }
        let packet = MQTTConnectPacket(
            cleanSession: cleanSession,
            keepAliveSeconds: UInt16(configuration.keepAliveInterval.nanoseconds / 1_000_000_000),
            clientIdentifier: identifier,
            userName: configuration.userName,
            password: configuration.password,
            properties: properties,
            will: publish
        )

        var configuration = configuration
        if configuration.pingInterval == nil {
            configuration.pingInterval = TimeAmount.seconds(max(Int64(packet.keepAliveSeconds - 5), 5))
        }

        var cleanSession = packet.cleanSession
        // if connection has non zero session expiry then assume it doesnt clean session on close
        for p in packet.properties {
            // check topic alias
            if case .sessionExpiryInterval(let interval) = p {
                if interval > 0 {
                    cleanSession = false
                }
            }
        }

        let future =
            if eventLoop.inEventLoop {
                self._makeConnection(
                    address: address,
                    configuration: configuration,
                    cleanSession: cleanSession,
                    identifier: identifier,
                    eventLoop: eventLoop,
                    logger: logger
                )
            } else {
                eventLoop.flatSubmit {
                    self._makeConnection(
                        address: address,
                        configuration: configuration,
                        cleanSession: cleanSession,
                        identifier: identifier,
                        eventLoop: eventLoop,
                        logger: logger
                    )
                }
            }
        let connection = try await future.get()
        try await connection.channelHandler.waitOnInitialized().get()
        _ = try await connection._connect(packet: packet)
        return connection
    }

    /// Close connection
    public func close() throws {
        guard self.isClosed.compareExchange(expected: false, desired: true, successOrdering: .relaxed, failureOrdering: .relaxed).exchanged
        else {
            return
        }
        if self.channel.isActive {
            let disconnectPacket: MQTTDisconnectPacket =
                switch self.configuration.versionConfiguration {
                case .v3_1_1:
                    MQTTDisconnectPacket()
                case .v5_0(_, let disconnectProperties, _, _):
                    MQTTDisconnectPacket(properties: disconnectProperties)
                }
            try self.sendMessageNoWait(disconnectPacket)
        }
        self.channel.close(mode: .all, promise: nil)
    }

    private static func _makeConnection(
        address: MQTTServerAddress,
        configuration: MQTTConnectionConfiguration,
        cleanSession: Bool,
        identifier: String,
        eventLoop: any EventLoop,
        logger: Logger
    ) -> EventLoopFuture<MQTTConnection> {
        eventLoop.assertInEventLoop()

        let host =
            switch address.value {
            case .hostname(let hostname, _):
                hostname
            case .unixDomainSocket(let path):
                path
            }

        let channelPromise = eventLoop.makePromise(of: (any Channel).self)
        do {
            let connect = try Self._getBootstrap(configuration: configuration, eventLoopGroup: eventLoop, host: host, logger: logger)
                .connectTimeout(configuration.connectTimeout)
                .channelInitializer { channel in
                    do {
                        // are we using websockets
                        if let webSocketConfiguration = configuration.webSocketConfiguration {
                            // prepare for websockets and on upgrade add handlers
                            let promise = eventLoop.makePromise(of: Void.self)
                            promise.futureResult.map { _ in channel }
                                .cascade(to: channelPromise)

                            return Self._setupChannelForWebSockets(
                                channel,
                                address: address,
                                configuration: configuration,
                                webSocketConfiguration: webSocketConfiguration,
                                upgradePromise: promise
                            ) {
                                try self._setupChannel(channel, configuration: configuration, logger: logger)
                            }
                        } else {
                            try self._setupChannel(channel, configuration: configuration, logger: logger)
                        }
                        return eventLoop.makeSucceededVoidFuture()
                    } catch {
                        channelPromise.fail(error)
                        return eventLoop.makeFailedFuture(error)
                    }
                }

            let future: EventLoopFuture<any Channel>
            switch address.value {
            case .hostname(let host, let port):
                future = connect.connect(host: host, port: port)
                future.whenSuccess { _ in
                    logger.debug("Client connected to \(host):\(port)")
                }
            case .unixDomainSocket(let path):
                future = connect.connect(unixDomainSocketPath: path)
                future.whenSuccess { _ in
                    logger.debug("Client connected to socket path \(path)")
                }
            }

            future
                .map { channel in
                    if !configuration.useWebSockets {
                        channelPromise.succeed(channel)
                    }
                }
                .cascadeFailure(to: channelPromise)
        } catch {
            channelPromise.fail(error)
        }

        return channelPromise.futureResult.flatMapThrowing { channel in
            let handler = try channel.pipeline.syncOperations.handler(type: MQTTChannelHandler.self)
            return MQTTConnection(
                channel: channel,
                channelHandler: handler,
                configuration: configuration,
                cleanSession: cleanSession,
                identifier: identifier,
                address: address,
                logger: logger
            )
        }
    }

    @discardableResult
    private static func _setupChannel(
        _ channel: any Channel,
        configuration: MQTTConnectionConfiguration,
        logger: Logger
    ) throws -> MQTTChannelHandler {
        channel.eventLoop.assertInEventLoop()
        let mqttChannelHandler = MQTTChannelHandler(
            configuration: MQTTChannelHandler.Configuration(configuration),
            eventLoop: channel.eventLoop,
            logger: logger
        )
        try channel.pipeline.syncOperations.addHandler(mqttChannelHandler)
        return mqttChannelHandler
    }

    private static func _getBootstrap(
        configuration: MQTTConnectionConfiguration,
        eventLoopGroup: any EventLoopGroup,
        host: String,
        logger: Logger
    ) throws -> NIOClientTCPBootstrap {
        var bootstrap: NIOClientTCPBootstrap
        let serverName = configuration.sniServerName ?? host
        #if canImport(Network)
        // if eventLoop is compatible with NIOTransportServices create a NIOTSConnectionBootstrap
        if let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoopGroup) {
            // create NIOClientTCPBootstrap with NIOTS TLS provider
            let options: NWProtocolTLS.Options
            switch configuration.tlsConfiguration {
            case .ts(let config):
                options = try config.getNWProtocolTLSOptions(logger: logger)
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
            if configuration.useSSL {
                return bootstrap.enableTLS()
            }
            return bootstrap
        }
        #endif

        #if os(macOS) || os(Linux)
        if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoopGroup) {
            let tlsConfiguration: TLSConfiguration
            switch configuration.tlsConfiguration {
            case .niossl(let config):
                tlsConfiguration = config
            default:
                tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            }
            if configuration.useSSL {
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

    private static func _setupChannelForWebSockets(
        _ channel: any Channel,
        address: MQTTServerAddress,
        configuration: MQTTConnectionConfiguration,
        webSocketConfiguration: MQTTConnectionConfiguration.WebSocketConfiguration,
        upgradePromise promise: EventLoopPromise<Void>,
        afterHandlerAdded: @escaping () throws -> Void
    ) -> EventLoopFuture<Void> {
        var hostHeader: String {
            switch (configuration.useSSL, address.value) {
            case (true, .hostname(let host, let port)) where port != 443:
                return "\(host):\(port)"
            case (false, .hostname(let host, let port)) where port != 80:
                return "\(host):\(port)"
            case (true, .hostname(let host, _)), (false, .hostname(let host, _)):
                return host
            case (true, .unixDomainSocket(let path)), (false, .unixDomainSocket(let path)):
                return path
            }
        }

        // initial HTTP request handler, before upgrade
        let httpHandler = WebSocketInitialRequestHandler(
            host: configuration.sniServerName ?? hostHeader,
            urlPath: webSocketConfiguration.urlPath,
            additionalHeaders: webSocketConfiguration.initialRequestHeaders,
            upgradePromise: promise
        )

        // create random key for request key
        let requestKey = (0..<16).map { _ in UInt8.random(in: .min ..< .max) }
        let websocketUpgrader = NIOWebSocketClientUpgrader(
            requestKey: Data(requestKey).base64EncodedString(),
            maxFrameSize: configuration.webSocketMaxFrameSize
        ) { channel, _ in
            let future = channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(WebSocketHandler())
                try afterHandlerAdded()
            }
            future.cascade(to: promise)
            return future
        }
        let upgradeConfig: NIOHTTPClientUpgradeConfiguration = (
            upgraders: [websocketUpgrader],
            completionHandler: { _ in
                channel.pipeline.removeHandler(httpHandler, promise: nil)
            }
        )

        // add HTTP handler with web socket upgrade
        return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: upgradeConfig).flatMap {
            channel.pipeline.addHandler(httpHandler)
        }
    }

    /// connect to broker
    func _connect(
        packet: MQTTConnectPacket,
        authWorkflow: (@Sendable (MQTTAuthV5) async throws -> MQTTAuthV5)? = nil
    ) async throws -> MQTTConnAckPacket {
        let message = try await self.sendMessage(packet) { message -> Bool in
            guard message.type == .CONNACK || message.type == .AUTH else { throw MQTTError.failedToConnect }
            return true
        }

        // process connack or auth messages
        switch message {
        case let connack as MQTTConnAckPacket:
            if connack.sessionPresent {
                try await self.resendOnRestart()
            } else {
                self.inflight.clear()
            }
            let ack = try self.processConnack(connack)
            return ack
        case let auth as MQTTAuthPacket:
            // auth messages require an auth workflow closure
            guard let authWorkflow else { throw MQTTError.authWorkflowRequired }
            let result = try await self.processAuth(auth, authWorkflow: authWorkflow)
            // once auth workflow is finished we should receive a connack
            guard let connAckPacket = result as? MQTTConnAckPacket else { throw MQTTError.unexpectedMessage }
            return connAckPacket
        default:
            throw MQTTError.unexpectedMessage
        }
    }

    func sendMessageNoWait(_ message: MQTTPacket) throws {
        try self.channelHandler.sendMessageNoWait(message)
    }

    func sendMessage(
        _ message: any MQTTPacket,
        checkInbound: @escaping (MQTTPacket) throws -> Bool
    ) async throws -> MQTTPacket {
        try await withCheckedThrowingContinuation { continuation in
            self.channelHandler.sendMessage(message, promise: .swift(continuation), checkInbound: checkInbound)
        }
    }

    /// Resend PUBLISH and PUBREL messages
    func resendOnRestart() async throws {
        let inflight = self.inflight.packets
        self.inflight.clear()
        for packet in inflight {
            switch packet {
            case let publish as MQTTPublishPacket:
                let newPacket = MQTTPublishPacket(
                    publish: .init(
                        qos: publish.publish.qos,
                        retain: publish.publish.retain,
                        dup: true,
                        topicName: publish.publish.topicName,
                        payload: publish.publish.payload,
                        properties: publish.publish.properties
                    ),
                    packetId: publish.packetId
                )
                _ = try await self.publish(packet: newPacket)
            case let pubRel as MQTTPubAckPacket:
                _ = try await self.pubRel(packet: pubRel)
            default:
                break
            }
        }
    }

    func processConnack(_ connack: MQTTConnAckPacket) throws -> MQTTConnAckPacket {
        // connack doesn't return a packet id so this is always 32767. Need a better way to choose first packet id
        self.globalPacketId.store(connack.packetId + 32767, ordering: .relaxed)
        switch self.configuration.version {
        case .v3_1_1:
            if connack.returnCode != 0 {
                let returnCode = MQTTError.ConnectionReturnValue(rawValue: connack.returnCode) ?? .unrecognizedReturnValue
                throw MQTTError.connectionError(returnCode)
            }
        case .v5_0:
            if connack.returnCode > 0x7F {
                let returnCode = MQTTReasonCode(rawValue: connack.returnCode) ?? .unrecognisedReason
                throw MQTTError.reasonError(returnCode)
            }
        }

        for property in connack.properties.properties {
            // alter pingreq interval based on session expiry returned from server
            if case .serverKeepAlive(let keepAliveInterval) = property {
                let pingTimeout = TimeAmount.seconds(max(Int64(keepAliveInterval - 5), 5))
                self.channelHandler.updatePingreqTimeout(pingTimeout)
            }
            // client identifier
            if case .assignedClientIdentifier(let identifier) = property {
                self.identifier = identifier
            }
            // max QoS
            if case .maximumQoS(let qos) = property {
                self.connectionParameters.maxQoS = qos
            }
            // max packet size
            if case .maximumPacketSize(let maxPacketSize) = property {
                self.connectionParameters.maxPacketSize = Int(maxPacketSize)
            }
            // supports retain
            if case .retainAvailable(let retainValue) = property, let retainAvailable = (retainValue != 0 ? true : false) {
                self.connectionParameters.retainAvailable = retainAvailable
            }
            // max topic alias
            if case .topicAliasMaximum(let max) = property {
                self.connectionParameters.maxTopicAlias = max
            }
        }
        return connack
    }

    func processAuth(
        _ packet: MQTTAuthPacket,
        authWorkflow: @Sendable @escaping (MQTTAuthV5) async throws -> MQTTAuthV5
    ) async throws -> any MQTTPacket {
        let auth = MQTTAuthV5(reason: packet.reason, properties: packet.properties)
        _ = try await authWorkflow(auth)
        let responsePacket = MQTTAuthPacket(reason: packet.reason, properties: packet.properties)
        let result = try await self.sendMessage(responsePacket) { message -> Bool in
            guard message.type == .CONNACK || message.type == .AUTH else { throw MQTTError.failedToConnect }
            return true
        }
        switch result {
        case let connack as MQTTConnAckPacket:
            return connack
        case let auth as MQTTAuthPacket:
            switch auth.reason {
            case .continueAuthentication:
                return try await processAuth(auth, authWorkflow: authWorkflow)
            case .success:
                return auth
            default:
                throw MQTTError.badResponse
            }
        default:
            throw MQTTError.unexpectedMessage
        }
    }

    /// Publish message to topic
    /// - Parameters:
    ///     - packet: Publish packet
    func publish(packet: MQTTPublishPacket) async throws -> MQTTAckV5? {
        // check publish validity
        // check qos against server max qos
        guard self.connectionParameters.maxQoS.rawValue >= packet.publish.qos.rawValue else {
            throw MQTTPacketError.qosInvalid
        }
        // check if retain is available
        guard packet.publish.retain == false || self.connectionParameters.retainAvailable else {
            throw MQTTPacketError.retainUnavailable
        }
        for p in packet.publish.properties {
            // check topic alias
            if case .topicAlias(let alias) = p {
                guard alias <= self.connectionParameters.maxTopicAlias, alias != 0 else {
                    throw MQTTPacketError.topicAliasOutOfRange
                }
            }
            if case .subscriptionIdentifier = p {
                throw MQTTPacketError.publishIncludesSubscription
            }
        }
        // check topic name
        guard !packet.publish.topicName.contains(where: { $0 == "#" || $0 == "+" }) else {
            throw MQTTPacketError.invalidTopicName
        }

        if packet.publish.qos == .atMostOnce {
            // don't send a packet id if QOS is at most once. (MQTT-2.3.1-5)
            try self.sendMessageNoWait(packet)
            return nil
        }

        self.inflight.add(packet: packet)
        let ackPacket: any MQTTPacket
        do {
            ackPacket = try await self.sendMessage(packet) { message in
                guard message.packetId == packet.packetId else { return false }
                self.inflight.remove(id: packet.packetId)
                if packet.publish.qos == .atLeastOnce {
                    guard message.type == .PUBACK else {
                        throw MQTTError.unexpectedMessage
                    }
                } else if packet.publish.qos == .exactlyOnce {
                    guard message.type == .PUBREC else {
                        throw MQTTError.unexpectedMessage
                    }
                }
                if let pubAckPacket = message as? MQTTPubAckPacket {
                    if pubAckPacket.reason.rawValue > 0x7F {
                        throw MQTTError.reasonError(pubAckPacket.reason)
                    }
                }
                return true
            }
        } catch {
            // if publish caused server to close the connection then remove from inflight array
            if case MQTTError.serverDisconnection(let ack) = error,
                ack.reason == .malformedPacket
            {
                self.inflight.remove(id: packet.packetId)
            }
            throw error
        }
        let ackInfo = (ackPacket as? MQTTPubAckPacket).map { MQTTAckV5(reason: $0.reason, properties: $0.properties) }
        if packet.publish.qos == .exactlyOnce {
            let pubRelPacket = MQTTPubAckPacket(type: .PUBREL, packetId: packet.packetId)
            _ = try await self.pubRel(packet: pubRelPacket)
            return ackInfo
        }
        return ackInfo
    }

    func pubRel(packet: MQTTPubAckPacket) async throws -> any MQTTPacket {
        self.inflight.add(packet: packet)
        return try await self.sendMessage(packet) { message in
            guard message.packetId == packet.packetId else { return false }
            guard message.type != .PUBREC else { return false }
            self.inflight.remove(id: packet.packetId)
            guard message.type == .PUBCOMP else {
                throw MQTTError.unexpectedMessage
            }
            if let pubAckPacket = message as? MQTTPubAckPacket {
                if pubAckPacket.reason.rawValue > 0x7F {
                    throw MQTTError.reasonError(pubAckPacket.reason)
                }
            }
            return true
        }
    }

    func updatePacketId() -> UInt16 {
        let id = self.globalPacketId.wrappingAdd(1, ordering: .relaxed).newValue
        // packet id must be non-zero
        return id == 0 ? self.globalPacketId.wrappingAdd(1, ordering: .relaxed).newValue : id
    }
}

extension MQTTConnection {
    /// Connection parameters. Limits set by either client or server.
    struct ConnectionParameters {
        var maxQoS: MQTTQoS = .exactlyOnce
        var maxPacketSize: Int?
        var retainAvailable: Bool = true
        var maxTopicAlias: UInt16 = 65535
    }
}
