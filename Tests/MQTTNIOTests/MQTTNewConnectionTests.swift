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

@Suite("MQTTNewConnection Tests")
struct MQTTNewConnectionTests {
    @Test("Connect with Will")
    func connectWithWill() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(MQTTNIOTests.hostname),
            identifier: "connectWithWill",
            will: (topicName: "MyWillTopic", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce, retain: false),
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Ping")
    func ping() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(MQTTNIOTests.hostname),
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
            address: .hostname(MQTTNIOTests.hostname, port: 1884),
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
                address: .hostname(MQTTNIOTests.hostname, port: 1884),
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
            address: .hostname(MQTTNIOTests.hostname, port: 8080),
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
            address: .hostname(MQTTNIOTests.hostname, port: 8883),
            configuration: .init(
                useSSL: true,
                tlsConfiguration: MQTTNIOTests.getTLSConfiguration(),
                sniServerName: "soto.codes"
            ),
            identifier: "tlsConnect",
            eventLoop: MQTTNIOTests.eventLoopGroupSingleton.any(),
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Connect with WebSocket and TLS")
    func webSocketAndTLSConnect() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(MQTTNIOTests.hostname, port: 8081),
            configuration: .init(
                timeout: .seconds(5),
                useSSL: true,
                tlsConfiguration: MQTTNIOTests.getTLSConfiguration(),
                sniServerName: "soto.codes",
                webSocketConfiguration: .init()
            ),
            identifier: "webSocketAndTLSConnect",
            eventLoop: MQTTNIOTests.eventLoopGroupSingleton.any(),
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    #if canImport(Network)
    @Test("Connect with TLS from P12")
    func tlsConnectFromP12() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(MQTTNIOTests.hostname, port: 8883),
            configuration: .init(
                useSSL: true,
                tlsConfiguration: .ts(
                    .init(
                        trustRoots: .der(MQTTNIOTests.rootPath + "/mosquitto/certs/ca.der"),
                        clientIdentity: .p12(filename: MQTTNIOTests.rootPath + "/mosquitto/certs/client.p12", password: "MQTTNIOClientCertPassword")
                    )
                ),
                sniServerName: "soto.codes"
            ),
            identifier: "tlsConnectFromP12",
            eventLoop: MQTTNIOTests.eventLoopGroupSingleton.any(),
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }
    #endif

    @Test("Connect with Unix Domain Socket")
    func unixDomainSocketConnect() async throws {
        try await MQTTNewConnection.withConnection(
            address: .unixDomainSocket(path: MQTTNIOTests.rootPath + "/mosquitto/socket/mosquitto.sock"),
            identifier: "unixDomainSocketConnect",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Publish", arguments: MQTTQoS.allCases)
    func publish(qos: MQTTQoS) async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(MQTTNIOTests.hostname),
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
            address: .hostname(MQTTNIOTests.hostname),
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
                address: .hostname(MQTTNIOTests.hostname),
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
            address: .hostname(MQTTNIOTests.hostname),
            identifier: "packetID",
            logger: self.logger
        ) { connection in
            let initial = await connection._testPacketId()
            try await connection.publish(
                to: "testPersistentAtLeastOnce",
                payload: ByteBufferAllocator().buffer(capacity: 0),
                qos: .atLeastOnce
            )
            let afterFirst = await connection._testPacketId()
            #expect(afterFirst == initial + 1)
            try await connection.publish(
                to: "testPersistentAtLeastOnce",
                payload: ByteBufferAllocator().buffer(capacity: 0),
                qos: .atLeastOnce
            )
            let afterSecond = await connection._testPacketId()
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
            return true
        case (.connectionError(let lhsValue), .connectionError(let rhsValue)):
            return lhsValue == rhsValue
        case (.reasonError(let lhsValue), .reasonError(let rhsValue)):
            return lhsValue == rhsValue
        default:
            return false
        }
    }
}

// Test-only helper to access packet id inside actor context
extension MQTTNewConnection {
    func _testPacketId() -> UInt16 { self.globalPacketId.load(ordering: .relaxed) }
}
