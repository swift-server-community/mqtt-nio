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

import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import Testing

@testable import MQTTNIO

#if canImport(Network)
import NIOTransportServices
#endif
#if os(macOS) || os(Linux)
import NIOSSL
#endif

@Suite("MQTTNewConnection Tests", .serialized)
struct MQTTNewConnectionTests {
    static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"

    @Test("Connect with Will")
    func connectWithWill() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(
                versionConfiguration: .v3_1_1(
                    will: (topicName: "MyWillTopic", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce, retain: false)
                )
            ),
            identifier: "connectWithWill",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Ping")
    func ping() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(pingInterval: .seconds(2)),
            identifier: "ping",
            logger: self.logger
        ) { connection in
            try await Task.sleep(for: .seconds(5))
        }
    }

    @Test("Connect with Username and Password")
    func connectWithUsernameAndPassword() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname, port: 1884),
            configuration: .init(userName: "mqttnio", password: "mqttnio-password"),
            identifier: "connectWithUsernameAndPassword",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Connect with Wrong Username and Password")
    func connectWithWrongUsernameAndPassword() async throws {
        await #expect(throws: MQTTError.connectionError(.notAuthorized)) {
            try await MQTTNewConnection.withConnection(
                address: .hostname(Self.hostname, port: 1884),
                configuration: .init(userName: "wrong", password: "wrong"),
                identifier: "connectWithWrongUsernameAndPassword",
                logger: self.logger
            ) { connection in
                try await connection.ping()
            }
        }
    }

    @Test("Connect with WebSocket")
    func webSocketConnect() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname, port: 8080),
            configuration: .init(webSocketConfiguration: .init()),
            identifier: "webSocketConnect",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Connect with TLS")
    func tlsConnect() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname, port: 8883),
            configuration: .init(
                useSSL: true,
                tlsConfiguration: Self.getTLSConfiguration(),
                sniServerName: "soto.codes"
            ),
            identifier: "tlsConnect",
            eventLoop: Self.eventLoopGroupSingleton.any(),
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Connect with WebSocket and TLS")
    func webSocketAndTLSConnect() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname, port: 8081),
            configuration: .init(
                timeout: .seconds(5),
                useSSL: true,
                tlsConfiguration: Self.getTLSConfiguration(),
                sniServerName: "soto.codes",
                webSocketConfiguration: .init()
            ),
            identifier: "webSocketAndTLSConnect",
            eventLoop: Self.eventLoopGroupSingleton.any(),
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    #if canImport(Network)
    @Test("Connect with TLS from P12")
    func tlsConnectFromP12() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname, port: 8883),
            configuration: .init(
                useSSL: true,
                tlsConfiguration: .ts(
                    .init(
                        trustRoots: .der(Self.rootPath + "/mosquitto/certs/ca.der"),
                        clientIdentity: .p12(filename: Self.rootPath + "/mosquitto/certs/client.p12", password: "MQTTNIOClientCertPassword")
                    )
                ),
                sniServerName: "soto.codes"
            ),
            identifier: "tlsConnectFromP12",
            eventLoop: Self.eventLoopGroupSingleton.any(),
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }
    #endif

    @Test("Connect with Unix Domain Socket")
    func unixDomainSocketConnect() async throws {
        try await MQTTNewConnection.withConnection(
            address: .unixDomainSocket(path: Self.rootPath + "/mosquitto/socket/mosquitto.sock"),
            identifier: "unixDomainSocketConnect",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Publish", arguments: MQTTQoS.allCases)
    func publish(qos: MQTTQoS) async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "publishQoS\(qos.rawValue)",
            logger: self.logger
        ) { connection in
            try await connection.publish(
                to: "testMQTTPublishQoS",
                payload: ByteBufferAllocator().buffer(string: "Test Payload"),
                qos: qos
            )
        }
    }

    @Test("PINGREQ")
    func pingreq() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "pingreq",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Server Close")
    func serverClose() async throws {
        struct MQTTForceDisconnectMessage: MQTTPacket {
            var type: MQTTPacketType { .PUBLISH }
            var description: String { "FORCEDISCONNECT" }

            func write(version: MQTTClient.Version, to byteBuffer: inout ByteBuffer) throws {
                // writing publish header with no content will cause a disconnect from the server
                byteBuffer.writeInteger(UInt8(0x30))
                byteBuffer.writeInteger(UInt8(0x0))
            }

            static func read(version: MQTTClient.Version, from packet: MQTTIncomingPacket) throws -> Self {
                throw InternalError.notImplemented
            }
        }

        await #expect(throws: MQTTError.serverClosedConnection) {
            try await MQTTNewConnection.withConnection(
                address: .hostname(Self.hostname),
                identifier: "serverDisconnect",
                logger: self.logger
            ) { connection in
                try await connection.sendMessage(MQTTForceDisconnectMessage()) { _ in true }
            }
        }
    }

    #if os(macOS)
    @Test("Connect with Raw IP Address")
    func rawIPConnect() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname("127.0.0.1"),
            identifier: "rawIPConnect",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }
    #endif

    @Test("Packet ID")
    func packetID() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "packetID",
            logger: self.logger
        ) { connection in
            let initial = await connection.globalPacketId.load(ordering: .relaxed)
            try await connection.publish(
                to: "testPersistentAtLeastOnce",
                payload: ByteBufferAllocator().buffer(capacity: 0),
                qos: .atLeastOnce
            )
            let afterFirst = await connection.globalPacketId.load(ordering: .relaxed)
            #expect(afterFirst == initial + 1)
            try await connection.publish(
                to: "testPersistentAtLeastOnce",
                payload: ByteBufferAllocator().buffer(capacity: 0),
                qos: .atLeastOnce
            )
            let afterSecond = await connection.globalPacketId.load(ordering: .relaxed)
            #expect(afterSecond == initial + 2)
        }
    }

    @Test("WebSocket Initial Request")
    func webSocketInitialRequest() throws {
        let el = EmbeddedEventLoop()
        defer { #expect(throws: Never.self) { try el.syncShutdownGracefully() } }
        let promise = el.makePromise(of: Void.self)
        let initialRequestHandler = WebSocketInitialRequestHandler(
            host: "test.mosquitto.org",
            urlPath: "/mqtt",
            additionalHeaders: ["Test": "Value"],
            upgradePromise: promise
        )
        let channel = EmbeddedChannel(handler: initialRequestHandler, loop: el)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        let requestHead = try channel.readOutbound(as: HTTPClientRequestPart.self)
        let requestBody = try channel.readOutbound(as: HTTPClientRequestPart.self)
        let requestEnd = try channel.readOutbound(as: HTTPClientRequestPart.self)
        switch requestHead {
        case .head(let head):
            #expect(head.uri == "/mqtt")
            #expect(head.headers["host"].first == "test.mosquitto.org")
            #expect(head.headers["Sec-WebSocket-Protocol"].first == "mqtt")
            #expect(head.headers["Test"].first == "Value")
        default:
            Issue.record("Unexpected request head: \(String(describing: requestHead))")
        }
        switch requestBody {
        case .body(let data):
            #expect(data == .byteBuffer(ByteBuffer()))
        default:
            Issue.record("Unexpected request body: \(String(describing: requestBody))")
        }
        switch requestEnd {
        case .end(nil):
            break
        default:
            Issue.record("Unexpected request end: \(String(describing: requestEnd))")
        }
        _ = try channel.finish()
        promise.succeed(())
    }

    let logger: Logger = {
        var logger = Logger(label: "MQTTNIOTests")
        logger.logLevel = .trace
        return logger
    }()

    static let rootPath = #filePath
        .split(separator: "/", omittingEmptySubsequences: false)
        .dropLast(3)
        .joined(separator: "/")

    static var eventLoopGroupSingleton: EventLoopGroup {
        #if os(Linux)
        MultiThreadedEventLoopGroup.singleton
        #else
        // Return TS Eventloop for non-Linux builds, as we use TS TLS
        NIOTSEventLoopGroup.singleton
        #endif
    }

    static var _tlsConfiguration: MQTTClient.TLSConfigurationType {
        get throws {
            #if os(Linux)
            let rootCertificate = try NIOSSLCertificate.fromPEMFile(Self.rootPath + "/mosquitto/certs/ca.pem")
            let certificate = try NIOSSLCertificate.fromPEMFile(Self.rootPath + "/mosquitto/certs/client.pem")
            let privateKey = try NIOSSLPrivateKey(file: Self.rootPath + "/mosquitto/certs/client.key", format: .pem)
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.trustRoots = .certificates(rootCertificate)
            tlsConfiguration.certificateChain = certificate.map { .certificate($0) }
            tlsConfiguration.privateKey = .privateKey(privateKey)
            return .niossl(tlsConfiguration)
            #else
            let caData = try Data(contentsOf: URL(fileURLWithPath: Self.rootPath + "/mosquitto/certs/ca.der"))
            let trustRootCertificates = SecCertificateCreateWithData(nil, caData as CFData).map { [$0] }
            let p12Data = try Data(contentsOf: URL(fileURLWithPath: Self.rootPath + "/mosquitto/certs/client.p12"))
            let options: [String: String] = [kSecImportExportPassphrase as String: "MQTTNIOClientCertPassword"]
            var rawItems: CFArray?
            guard SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems) == errSecSuccess else {
                throw MQTTError.wrongTLSConfig
            }
            let items = rawItems! as! [[String: Any]]
            let firstItem = items[0]
            let identity = firstItem[kSecImportItemIdentity as String] as! SecIdentity?
            let tlsConfiguration = TSTLSConfiguration(
                trustRoots: trustRootCertificates,
                clientIdentity: identity
            )
            return .ts(tlsConfiguration)
            #endif
        }
    }

    static func getTLSConfiguration(
        withTrustRoots: Bool = true,
        withClientKey: Bool = true
    ) throws -> MQTTConnectionConfiguration.TLSConfigurationType {
        switch try Self._tlsConfiguration {
        #if os(macOS) || os(Linux)
        case .niossl(let config):
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.trustRoots = withTrustRoots ? (config.trustRoots ?? .default) : .default
            tlsConfig.certificateChain = withClientKey ? config.certificateChain : []
            tlsConfig.privateKey = withClientKey ? config.privateKey : nil
            return .niossl(tlsConfig)
        #endif
        #if canImport(Network)
        case .ts(let config):
            return .ts(
                TSTLSConfiguration(
                    trustRoots: withTrustRoots ? config.trustRoots : nil,
                    clientIdentity: withClientKey ? config.clientIdentity : nil
                )
            )
        #endif
        }
    }
}

extension MQTTError: Equatable {
    public static func == (lhs: MQTTError, rhs: MQTTError) -> Bool {
        switch (lhs, rhs) {
        case (.alreadyConnected, .alreadyConnected),
            (.alreadyShutdown, .alreadyShutdown),
            (.failedToConnect, .failedToConnect),
            (.noConnection, .noConnection),
            (.serverClosedConnection, .serverClosedConnection),
            (.unexpectedMessage, .unexpectedMessage),
            (.decodeError, .decodeError),
            (.websocketUpgradeFailed, .websocketUpgradeFailed),
            (.timeout, .timeout),
            (.retrySend, .retrySend),
            (.wrongTLSConfig, .wrongTLSConfig),
            (.badResponse, .badResponse),
            (.unrecognisedPacketType, .unrecognisedPacketType),
            (.authWorkflowRequired, .authWorkflowRequired),
            (.serverDisconnection, .serverDisconnection):
            true
        case (.connectionError(let lhsValue), .connectionError(let rhsValue)):
            lhsValue == rhsValue
        case (.reasonError(let lhsValue), .reasonError(let rhsValue)):
            lhsValue == rhsValue
        default:
            false
        }
    }
}
