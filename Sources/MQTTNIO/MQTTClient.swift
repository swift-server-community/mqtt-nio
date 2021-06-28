import Foundation
import Logging
#if canImport(Network)
import Network
#endif
import NIO
import NIOConcurrencyHelpers
#if canImport(NIOSSL)
import NIOSSL
#endif
import NIOTransportServices

/// Swift NIO MQTT Client
public final class MQTTClient {
    /// EventLoopGroup used by MQTTCllent
    public let eventLoopGroup: EventLoopGroup
    /// How was EventLoopGroup provided to the client
    let eventLoopGroupProvider: NIOEventLoopGroupProvider
    /// Host name of server to connect to
    public let host: String
    /// Port to connect to
    public let port: Int
    /// client identifier
    public private(set) var identifier: String
    /// logger
    public var logger: Logger
    /// Client configuration
    public let configuration: Configuration

    /// Connection client is using
    var connection: MQTTConnection? {
        get {
            self.lock.withLock {
                _connection
            }
        }
        set {
            self.lock.withLock {
                _connection = newValue
            }
        }
    }

    var hostHeader: String {
        if (self.configuration.useSSL && self.port != 443) || (!self.configuration.useSSL && self.port != 80) {
            return "\(self.host):\(self.port)"
        }
        return self.host
    }

    private let globalPacketId = NIOAtomic<UInt16>.makeAtomic(value: 1)
    /// default logger that logs nothing
    private static let loggingDisabled = Logger(label: "MQTT-do-not-log", factory: { _ in SwiftLogNoOpLogHandler() })
    /// inflight messages
    private var inflight: MQTTInflight

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
        identifier: String,
        eventLoopGroupProvider: NIOEventLoopGroupProvider,
        logger: Logger? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.host = host
        if let port = port {
            self.port = port
        } else {
            switch (configuration.useSSL, configuration.useWebSockets) {
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
        self.identifier = identifier
        self.configuration = configuration
        self._connection = nil
        self.logger = (logger ?? Self.loggingDisabled).attachingClientIdentifier(self.identifier)
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch eventLoopGroupProvider {
        case .createNew:
            #if canImport(Network)
            switch configuration.tlsConfiguration {
            #if canImport(NIOSSL)
            case .niossl:
                self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            #endif
            case .ts, .none:
                self.eventLoopGroup = NIOTSEventLoopGroup()
            }
            #else
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            #endif
        case .shared(let elg):
            self.eventLoopGroup = elg
        }
        self.inflight = .init()
    }

    /// Close down client. Must be called before the client is destroyed
    public func syncShutdownGracefully() throws {
        try self.connection?.close().wait()
        switch self.eventLoopGroupProvider {
        case .createNew:
            try self.eventLoopGroup.syncShutdownGracefully()
        case .shared:
            break
        }
    }

    /// Connect to MQTT server
    ///
    /// If `cleanSession` is set to false the Server MUST resume communications with the Client based on state from the current Session (as identified by the Client identifier).
    /// If there is no Session associated with the Client identifier the Server MUST create a new Session. The Client and Server MUST store the Session
    /// after the Client and Server are disconnected. If set to true then the Client and Server MUST discard any previous Session and start a new one
    ///
    /// The function returns an EventLoopFuture which will be updated with whether the server has restored a session for this client.
    ///
    /// - Parameters:
    ///   - cleanSession: should we start with a new session
    ///   - will: Publish message to be posted as soon as connection is made
    /// - Returns: EventLoopFuture to be updated with whether server holds a session for this client
    public func connect(
        cleanSession: Bool = true,
        will: (topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool)? = nil
    ) -> EventLoopFuture<Bool> {
        let publish = will.map {
            MQTTPublishInfo(
                qos: .atMostOnce,
                retain: $0.retain,
                dup: false,
                topicName: $0.topicName,
                payload: $0.payload,
                properties: .init()
            )
        }
        var properties = MQTTProperties()
        if self.configuration.version == .v5_0, cleanSession == false {
            properties.append(.sessionExpiryInterval(0xFFFF_FFFF))
        }
        let packet = MQTTConnectPacket(
            cleanSession: cleanSession,
            keepAliveSeconds: UInt16(configuration.keepAliveInterval.nanoseconds / 1_000_000_000),
            clientIdentifier: self.identifier,
            userName: self.configuration.userName,
            password: self.configuration.password,
            properties: properties,
            will: publish
        )

        return self.connect(packet: packet).map { $0.sessionPresent }
    }

    /// Publish message to topic
    /// - Parameters:
    ///     - topicName: Topic name on which the message is published
    ///     - payload: Message payload
    ///     - qos: Quality of Service for message.
    ///     - retain: Whether this is a retained message.
    /// - Returns: Future waiting for publish to complete. Depending on QoS setting the future will complete
    ///     when message is sent, when PUBACK is received or when PUBREC and following PUBCOMP are
    ///     received
    public func publish(
        to topicName: String,
        payload: ByteBuffer,
        qos: MQTTQoS,
        retain: Bool = false,
        properties: MQTTProperties = .init()
    ) -> EventLoopFuture<Void> {
        let info = MQTTPublishInfo(qos: qos, retain: retain, dup: false, topicName: topicName, payload: payload, properties: properties)
        let packetId = self.updatePacketId()
        let packet = MQTTPublishPacket(publish: info, packetId: packetId)
        return self.publish(packet: packet).map { _ in }
    }

    /// Subscribe to topic
    /// - Parameter subscriptions: Subscription infos
    /// - Returns: Future waiting for subscribe to complete. Will wait for SUBACK message from server
    public func subscribe(to subscriptions: [MQTTSubscribeInfo]) -> EventLoopFuture<MQTTSuback> {
        let packetId = self.updatePacketId()
        let subscriptions: [MQTTSubscribeInfoV5] = subscriptions.map { .init(topicFilter: $0.topicFilter, qos: $0.qos) }
        let packet = MQTTSubscribePacket(subscriptions: subscriptions, properties: .init(), packetId: packetId)
        return self.subscribe(packet: packet)
            .map { message in
                let returnCodes = message.reasons.map { MQTTSuback.ReturnCode(rawValue: $0.rawValue) ?? .failure }
                return MQTTSuback(returnCodes: returnCodes)
            }
    }

    /// Unsubscribe from topic
    /// - Parameter subscriptions: List of subscriptions to unsubscribe from
    /// - Returns: Future waiting for unsubscribe to complete. Will wait for UNSUBACK message from server
    public func unsubscribe(from subscriptions: [String]) -> EventLoopFuture<Void> {
        let packetId = self.updatePacketId()
        let packet = MQTTUnsubscribePacket(subscriptions: subscriptions, properties: .init(), packetId: packetId)
        return self.unsubscribe(packet: packet)
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
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(MQTTError.noConnection) }

        return connection.sendMessage(MQTTPingreqPacket()) { message in
            guard message.type == .PINGRESP else { return false }
            return true
        }
        .map { _ in }
    }

    /// Disconnect from server
    /// - Returns: Future waiting on disconnect message to be sent
    public func disconnect() -> EventLoopFuture<Void> {
        return self.disconnect(packet: MQTTDisconnectPacket())
    }

    /// Return is client has an active connection to broker
    public func isActive() -> Bool {
        return self.connection?.channel.isActive ?? false
    }

    /// Add named publish listener. Called whenever a PUBLISH message is received from the server
    public func addPublishListener(named name: String, _ listener: @escaping (Result<MQTTPublishInfo, Swift.Error>) -> Void) {
        self.publishListeners.addListener(named: name, listener: listener)
    }

    /// Remove named publish listener
    public func removePublishListener(named name: String) {
        self.publishListeners.removeListener(named: name)
    }

    /// Add close listener. Called whenever the connection is closed
    public func addCloseListener(named name: String, _ listener: @escaping (Result<Void, Swift.Error>) -> Void) {
        self.closeListeners.addListener(named: name, listener: listener)
    }

    /// Remove named close listener
    public func removeCloseListener(named name: String) {
        self.closeListeners.removeListener(named: name)
    }

    internal func updatePacketId() -> UInt16 {
        // packet id must be non-zero
        if self.globalPacketId.compareAndExchange(expected: 0, desired: 1) {
            return 1
        } else {
            return self.globalPacketId.add(1)
        }
    }

    /// connection parameters. Limits set by either client or server
    struct ConnectionParameters {
        var maxQoS: MQTTQoS = .exactlyOnce
        var maxPacketSize: Int?
        var retainAvailable: Bool = true
        var maxTopicAlias: UInt16 = 65535
    }

    var connectionParameters = ConnectionParameters()
    var publishListeners = MQTTListeners<MQTTPublishInfo>()
    var closeListeners = MQTTListeners<Void>()
    private var _connection: MQTTConnection?
    private var lock = Lock()
}

extension MQTTClient {
    /// connect to broker
    func connect(
        packet: MQTTConnectPacket,
        authWorkflow: ((MQTTAuthV5, EventLoop) -> EventLoopFuture<MQTTAuthV5>)? = nil
    ) -> EventLoopFuture<MQTTConnAckPacket> {
        let pingInterval = self.configuration.pingInterval ?? TimeAmount.seconds(max(Int64(packet.keepAliveSeconds - 5), 5))

        let connectFuture = MQTTConnection.create(client: self, pingInterval: pingInterval)
        let eventLoop = connectFuture.eventLoop
        return connectFuture
            .flatMap { connection -> EventLoopFuture<MQTTPacket> in
                self.connection = connection
                connection.closeFuture.whenComplete { result in
                    // only reset connection if this connection is still set. Stops a reconnect having its connection removed by the
                    // previous connection
                    if self.connection === connection {
                        self.connection = nil
                    }
                    self.closeListeners.notify(result)
                }
                return connection.sendMessage(packet) { message -> Bool in
                    guard message.type == .CONNACK || message.type == .AUTH else { throw MQTTError.failedToConnect }
                    return true
                }
            }
            .flatMap { message in
                // process connack or auth messages
                switch message {
                case let connack as MQTTConnAckPacket:
                    do {
                        if connack.sessionPresent {
                            self.resendOnRestart()
                        } else {
                            self.inflight.clear()
                        }
                        let ack = try self.processConnack(connack)
                        return eventLoop.makeSucceededFuture(ack)
                    } catch {
                        return eventLoop.makeFailedFuture(error)
                    }
                case let auth as MQTTAuthPacket:
                    // auth messages require an auth workflow closure
                    guard let authWorkflow = authWorkflow else { return eventLoop.makeFailedFuture(MQTTError.authWorkflowRequired) }
                    return self.processAuth(auth, authWorkflow: authWorkflow, on: eventLoop)
                        .flatMapThrowing { result -> MQTTConnAckPacket in
                            // once auth workflow is finished we should receive a connack
                            guard let result = result as? MQTTConnAckPacket else { throw MQTTError.unexpectedMessage }
                            return result
                        }
                default:
                    return eventLoop.makeFailedFuture(MQTTError.unexpectedMessage)
                }
            }
    }

    /// Resend PUBLISH and PUBREL messages
    func resendOnRestart() {
        let inflight = self.inflight.packets
        self.inflight.clear()
        inflight.forEach { packet -> Void in
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
                _ = self.publish(packet: newPacket)
            case let pubRel as MQTTPubAckPacket:
                _ = self.pubRel(packet: pubRel)
            default:
                break
            }
        }
    }

    func processConnack(_ connack: MQTTConnAckPacket) throws -> MQTTConnAckPacket {
        // connack doesn't return a packet id so this is alway 32767. Need a better way to choose first packet id
        _ = self.globalPacketId.exchange(with: connack.packetId + 32767)
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
            if let connection = self.connection {
                if case .sessionExpiryInterval(let sessionExpiryInterval) = property {
                    let pingTimeout = TimeAmount.seconds(max(Int64(sessionExpiryInterval - 5), 5))
                    connection.updatePingreqTimeout(pingTimeout)
                }
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
        authWorkflow: @escaping ((MQTTAuthV5, EventLoop) -> EventLoopFuture<MQTTAuthV5>),
        on eventLoop: EventLoop
    ) -> EventLoopFuture<MQTTPacket> {
        let promise = eventLoop.makePromise(of: MQTTPacket.self)
        func workflow(_ packet: MQTTAuthPacket) {
            let auth = MQTTAuthV5(reason: packet.reason, properties: packet.properties)
            authWorkflow(auth, eventLoop)
                .flatMap { _ -> EventLoopFuture<MQTTPacket> in
                    let responsePacket = MQTTAuthPacket(reason: packet.reason, properties: packet.properties)
                    return self.auth(packet: responsePacket)
                }
                .map { result in
                    switch result {
                    case let connack as MQTTConnAckPacket:
                        promise.succeed(connack)
                    case let auth as MQTTAuthPacket:
                        switch auth.reason {
                        case .continueAuthentication:
                            workflow(auth)
                        case .success:
                            promise.succeed(auth)
                        default:
                            promise.fail(MQTTError.badResponse)
                        }
                    default:
                        promise.fail(MQTTError.unexpectedMessage)
                    }
                }
                .cascadeFailure(to: promise)
        }
        workflow(packet)
        return promise.futureResult
    }

    func auth(packet: MQTTAuthPacket) -> EventLoopFuture<MQTTPacket> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(MQTTError.noConnection) }

        return connection.sendMessage(packet) { message -> Bool in
            guard message.type == .CONNACK || message.type == .AUTH else { throw MQTTError.failedToConnect }
            return true
        }
    }

    /// Publish message to topic
    /// - Parameters:
    ///     - packet: Publish packet
    func publish(packet: MQTTPublishPacket) -> EventLoopFuture<MQTTAckV5?> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(MQTTError.noConnection) }

        // check publish validity
        // check qos against server max qos
        guard self.connectionParameters.maxQoS.rawValue >= packet.publish.qos.rawValue else {
            return self.eventLoopGroup.next().makeFailedFuture(MQTTPacketError.qosInvalid)
        }
        // check if retain is available
        guard packet.publish.retain == false || self.connectionParameters.retainAvailable else {
            return self.eventLoopGroup.next().makeFailedFuture(MQTTPacketError.retainUnavailable)
        }
        for p in packet.publish.properties {
            // check topic alias
            if case .topicAlias(let alias) = p {
                guard alias <= self.connectionParameters.maxTopicAlias, alias != 0 else {
                    return self.eventLoopGroup.next().makeFailedFuture(MQTTPacketError.topicAliasOutOfRange)
                }
            }
            if case .subscriptionIdentifier = p {
                return self.eventLoopGroup.next().makeFailedFuture(MQTTPacketError.publishIncludesSubscription)
            }
        }
        // check topic name
        guard !packet.publish.topicName.contains(where: { $0 == "#" || $0 == "+" }) else {
            return self.eventLoopGroup.next().makeFailedFuture(MQTTPacketError.invalidTopicName)
        }

        if packet.publish.qos == .atMostOnce {
            // don't send a packet id if QOS is at most once. (MQTT-2.3.1-5)
            return connection.sendMessageNoWait(packet).map { _ in nil }
        }

        self.inflight.add(packet: packet)
        return connection.sendMessage(packet) { message in
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
        .flatMapErrorThrowing { error in
            // if publish caused server to close the connection then remove from inflight array
            if case MQTTError.serverClosedConnection = error {
                self.inflight.remove(id: packet.packetId)
            }
            throw error
        }
        .flatMap { ackPacket in
            let ackPacket = ackPacket as? MQTTPubAckPacket
            let ackInfo = ackPacket.map { MQTTAckV5(reason: $0.reason, properties: $0.properties) }
            if packet.publish.qos == .exactlyOnce {
                let pubRelPacket = MQTTPubAckPacket(type: .PUBREL, packetId: packet.packetId)
                return self.pubRel(packet: pubRelPacket)
                    .map { _ in ackInfo }
            }
            return self.eventLoopGroup.next().makeSucceededFuture(ackInfo)
        }
    }

    func pubRel(packet: MQTTPubAckPacket) -> EventLoopFuture<MQTTPacket> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(MQTTError.noConnection) }
        self.inflight.add(packet: packet)
        return connection.sendMessage(packet) { message in
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

    /// Subscribe to topic
    /// - Parameter packet: Subscription packet
    /// - Returns: Future waiting for subscribe to complete. Will wait for SUBACK message from server
    func subscribe(packet: MQTTSubscribePacket) -> EventLoopFuture<MQTTSubAckPacket> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(MQTTError.noConnection) }
        guard packet.subscriptions.count > 0 else { return self.eventLoopGroup.next().makeFailedFuture(MQTTPacketError.atLeastOneTopicRequired) }

        return connection.sendMessage(packet) { message in
            guard message.packetId == packet.packetId else { return false }
            guard message.type == .SUBACK else { throw MQTTError.unexpectedMessage }
            return true
        }
        .flatMapThrowing { message in
            guard let suback = message as? MQTTSubAckPacket else { throw MQTTError.unexpectedMessage }
            return suback
        }
    }

    /// Unsubscribe from topic
    /// - Parameter subscriptions: List of subscriptions to unsubscribe from
    /// - Returns: Future waiting for unsubscribe to complete. Will wait for UNSUBACK message from server
    func unsubscribe(packet: MQTTUnsubscribePacket) -> EventLoopFuture<MQTTSubAckPacket> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(MQTTError.noConnection) }
        guard packet.subscriptions.count > 0 else { return self.eventLoopGroup.next().makeFailedFuture(MQTTPacketError.atLeastOneTopicRequired) }

        return connection.sendMessage(packet) { message in
            guard message.packetId == packet.packetId else { return false }
            guard message.type == .UNSUBACK else { throw MQTTError.unexpectedMessage }
            return true
        }
        .flatMapThrowing { message in
            guard let suback = message as? MQTTSubAckPacket else { throw MQTTError.unexpectedMessage }
            return suback
        }
    }

    /// Disconnect from server
    /// - Returns: Future waiting on disconnect message to be sent
    func disconnect(packet: MQTTDisconnectPacket) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(MQTTError.noConnection) }

        return connection.sendMessageNoWait(packet)
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
