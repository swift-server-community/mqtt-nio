//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2026 Adam Fowler
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
    /// Request ID generator
    @usableFromInline
    static let requestIDGenerator: IDGenerator = .init()
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
    ///   - operation: Closure handling the MQTT connection.
    ///     The closure receives the ``MQTTConnection`` and a `Bool` indicating if there was a previous session present.
    /// - Returns: Value returned from the operation closure.
    public static func withConnection<Value>(
        address: MQTTServerAddress,
        configuration: MQTTConnectionConfiguration = .init(),
        identifier: String,
        cleanSession: Bool = true,
        eventLoop: any EventLoop = MultiThreadedEventLoopGroup.singleton.any(),
        logger: Logger,
        operation: (MQTTConnection, Bool) async throws -> sending Value
    ) async throws -> sending Value {
        let (connection, sessionPresent) = try await self.connect(
            address: address,
            identifier: identifier,
            cleanSession: cleanSession,
            configuration: configuration,
            eventLoop: eventLoop,
            logger: logger
        )
        defer { connection.close() }
        return try await operation(connection, sessionPresent)
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
    ///   - operation: Closure handling the MQTT connection.
    /// - Returns: Value returned from the operation closure.
    public static func withConnection<Value>(
        address: MQTTServerAddress,
        configuration: MQTTConnectionConfiguration = .init(),
        identifier: String,
        cleanSession: Bool = true,
        eventLoop: any EventLoop = MultiThreadedEventLoopGroup.singleton.any(),
        logger: Logger,
        operation: (MQTTConnection) async throws -> sending Value
    ) async throws -> sending Value {
        try await Self.withConnection(
            address: address,
            configuration: configuration,
            identifier: identifier,
            cleanSession: cleanSession,
            eventLoop: eventLoop,
            logger: logger
        ) { connection, _ in
            try await operation(connection)
        }
    }

    /// Publish message to topic.
    ///
    /// - Parameters:
    ///     - topicName: Topic name on which the message is published.
    ///     - payload: Message payload.
    ///     - qos: Quality of Service for message.
    ///     - retain: Whether this is a retained message.
    public func publish(
        to topicName: String,
        payload: ByteBuffer,
        qos: MQTTQoS,
        retain: Bool = false,
    ) async throws {
        let info = MQTTPublishInfo(qos: qos, retain: retain, dup: false, topicName: topicName, payload: payload, properties: .init())
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

    /// Connect to MQTT server and return the connection and whether there was a previous session present.
    ///
    /// - Parameters:
    ///   - address: Internet address of the MQTT server.
    ///   - identifier: Client identifier for the server.
    ///   - cleanSession: Whether to start a clean session.
    ///   - configuration: Configuration of the MQTT connection.
    ///   - eventLoop: `EventLoop` to run the connection on.
    ///   - logger: `Logger` to use for the connection.
    ///
    /// - Returns: Tuple of the ``MQTTConnection`` and a `Bool` indicating if there was a previous session present.
    private static func connect(
        address: MQTTServerAddress,
        identifier: String,
        cleanSession: Bool,
        configuration: MQTTConnectionConfiguration,
        eventLoop: any EventLoop = MultiThreadedEventLoopGroup.singleton.any(),
        logger: Logger
    ) async throws -> (MQTTConnection, Bool) {
        var configuration = configuration
        if configuration.pingInterval == nil {
            configuration.pingInterval = TimeAmount.seconds(max(Int64(configuration.keepAliveInterval.nanoseconds / 1_000_000_000) - 5, 5))
        }
        let readOnlyConfiguration = configuration
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
                        configuration: readOnlyConfiguration,
                        cleanSession: cleanSession,
                        identifier: identifier,
                        eventLoop: eventLoop,
                        logger: logger
                    )
                }
            }
        let connection = try await future.get()
        try await connection.waitOnInitialized()
        let sessionPresent = try await connection.sendConnect()
        return (connection, sessionPresent)
    }

    func waitOnInitialized() async throws {
        try await self.channelHandler.waitOnInitialized().get()
    }

    /// Send CONNECT packet
    /// - Returns: Whether there was a previous session present.
    package func sendConnect() async throws -> Bool {
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
        let authenticator: MQTTAuthenticator?
        var properties: MQTTProperties
        (authenticator, properties) =
            switch configuration.versionConfiguration {
            case .v3_1_1:
                (nil, .init())
            case .v5_0(let connectProperties, _, _, let authenticator):
                (authenticator, connectProperties)
            }

        var cleanSession = self.cleanSession
        // if connection has non zero session expiry then assume it doesnt clean session on close
        for p in properties {
            // check topic alias
            if case .sessionExpiryInterval(let interval) = p {
                if interval > 0 {
                    cleanSession = false
                }
            }
        }
        if let authenticator {
            properties.addOrReplace(.authenticationMethod(authenticator.methodName))
        }
        let packet = MQTTConnectPacket(
            cleanSession: cleanSession,
            keepAliveSeconds: UInt16(configuration.keepAliveInterval.nanoseconds / 1_000_000_000),
            clientIdentifier: identifier,
            userName: configuration.authentication?.userName,
            password: configuration.authentication?.password,
            properties: properties,
            will: publish
        )
        return try await self._connect(packet: packet, authWorkflow: authenticator).sessionPresent
    }

    func sendDisconnect() throws {
        if channel.isActive {
            let disconnectPacket: MQTTDisconnectPacket =
                switch self.configuration.versionConfiguration {
                case .v3_1_1:
                    MQTTDisconnectPacket()
                case .v5_0(_, let disconnectProperties, _, _):
                    MQTTDisconnectPacket(properties: disconnectProperties)
                }
            try self.sendMessageNoWait(disconnectPacket)
        }
    }

    /// Close connection
    public nonisolated func close() {
        guard self.isClosed.compareExchange(expected: false, desired: true, successOrdering: .relaxed, failureOrdering: .relaxed).exchanged
        else {
            return
        }
        self.channel.eventLoop.execute {
            self.assumeIsolated {
                try? $0.sendDisconnect()
                $0.channel.close(mode: .all, promise: nil)
            }
        }
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

    package static func setupChannelAndConnect(
        _ channel: any Channel,
        configuration: MQTTConnectionConfiguration = .init(),
        cleanSession: Bool = false,
        identifier: String = "TestClient",
        logger: Logger
    ) async throws -> MQTTConnection {
        if !channel.eventLoop.inEventLoop {
            return try await channel.eventLoop.flatSubmit {
                self._setupChannelAndConnect(
                    channel,
                    configuration: configuration,
                    cleanSession: cleanSession,
                    identifier: identifier,
                    logger: logger
                )
            }.get()
        }
        return try await self._setupChannelAndConnect(
            channel,
            configuration: configuration,
            cleanSession: cleanSession,
            identifier: identifier,
            logger: logger
        ).get()
    }

    private static func _setupChannelAndConnect(
        _ channel: Channel,
        configuration: MQTTConnectionConfiguration,
        cleanSession: Bool,
        identifier: String,
        logger: Logger
    ) -> EventLoopFuture<MQTTConnection> {
        do {
            return channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1883)).flatMap {
                channel.eventLoop.makeCompletedFuture {
                    let handler = try self._setupChannel(
                        channel,
                        configuration: configuration,
                        logger: logger
                    )
                    return MQTTConnection(
                        channel: channel,
                        channelHandler: handler,
                        configuration: configuration,
                        cleanSession: cleanSession,
                        identifier: identifier,
                        address: .hostname("127.0.0.1", port: 1883),
                        logger: logger
                    )
                }
            }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
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
        var serverName: String {
            if case .enable(_, let sniServerName) = configuration.tls.base, let sniServerName {
                sniServerName
            } else {
                host
            }
        }

        let bootstrap: NIOClientTCPBootstrap
        #if canImport(Network)
        // if eventLoop is compatible with NIOTransportServices create a NIOTSConnectionBootstrap
        if let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoopGroup) {
            // create NIOClientTCPBootstrap with NIOTS TLS provider
            let options: NWProtocolTLS.Options
            if case .enable(let tlsConfigType, _) = configuration.tls.base {
                switch tlsConfigType {
                case .ts(let tsConfig):
                    options = try tsConfig.getNWProtocolTLSOptions(logger: logger)
                #if os(macOS) || os(Linux) || os(Android)
                case .niossl:
                    throw MQTTError.wrongTLSConfig
                #endif
                }
            } else {
                options = NWProtocolTLS.Options()
            }
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, serverName)
            let tlsProvider = NIOTSClientTLSProvider(tlsOptions: options)
            bootstrap = NIOClientTCPBootstrap(tsBootstrap, tls: tlsProvider)
            if case .enable = configuration.tls.base {
                return bootstrap.enableTLS()
            }
            return bootstrap
        }
        #endif

        #if os(macOS) || os(Linux)
        if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoopGroup) {
            if case .enable(let tlsConfig, _) = configuration.tls.base {
                let tlsConfiguration: TLSConfiguration
                switch tlsConfig {
                case .niossl(let config):
                    tlsConfiguration = config
                #if os(macOS)
                case .ts:
                    throw MQTTError.wrongTLSConfig
                #endif
                }
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
        afterHandlerAdded: @Sendable @escaping () throws -> Void
    ) -> EventLoopFuture<Void> {
        var hostHeader: String {
            if case .enable(_, let sniServerName) = configuration.tls.base, let sniServerName {
                return sniServerName
            }
            switch (configuration.tls.base, address.value) {
            case (.enable, .hostname(let host, let port)) where port != 443:
                return "\(host):\(port)"
            case (.disable, .hostname(let host, let port)) where port != 80:
                return "\(host):\(port)"
            case (.enable, .hostname(let host, _)), (.disable, .hostname(let host, _)):
                return host
            case (.enable, .unixDomainSocket(let path)), (.disable, .unixDomainSocket(let path)):
                return path
            }
        }

        // initial HTTP request handler, before upgrade
        let httpHandler = WebSocketInitialRequestHandler(
            host: hostHeader,
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
        let upgradeConfig: NIOHTTPClientUpgradeSendableConfiguration = (
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
        authWorkflow: MQTTAuthenticator?
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
        let requestID = Self.requestIDGenerator.next()
        return try await withTaskCancellationHandler {
            if Task.isCancelled {
                throw MQTTError.cancelledTask
            }
            return try await withCheckedThrowingContinuation { continuation in
                self.channelHandler.sendMessage(message, promise: .swift(continuation), requestID: requestID, checkInbound: checkInbound)
            }
        } onCancel: {
            self.cancel(requestID: requestID)
        }
    }

    @usableFromInline
    nonisolated func cancel(requestID: Int) {
        self.channel.eventLoop.execute {
            self.assumeIsolated { this in
                this.channelHandler.cancel(requestID: requestID)
            }
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
                self.channelHandler.maxPacketSize = maxPacketSize
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
        authWorkflow: MQTTAuthenticator
    ) async throws -> any MQTTPacket {
        let auth = MQTTAuthV5(reason: packet.reason, properties: packet.properties)
        // Authenticate
        var authResponse = try await authWorkflow.authenticate(auth)
        // Add authentication name to response
        authResponse.properties.append(.authenticationMethod(authWorkflow.methodName))
        let responsePacket = MQTTAuthPacket(reason: authResponse.reason, properties: authResponse.properties)
        // Send response
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
        var retainAvailable: Bool = true
        var maxTopicAlias: UInt16 = 65535
    }
}
