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

@Suite("Integration Tests")
struct IntegrationTests {
    static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"

    @Test("Connect with Will")
    func connectWithWill() async throws {
        try await MQTTConnection.withConnection(
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

    @Test("Keep Alive Ping")
    func keepAlivePing() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(pingInterval: .seconds(2)),
            identifier: "keepAlivePing",
            logger: self.logger
        ) { connection in
            try await Task.sleep(for: .seconds(5))
        }
    }

    @Test("Connect with Username and Password")
    func connectWithUsernameAndPassword() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname, port: 1884),
            configuration: .init(authentication: .init(userName: "mqttnio", password: "mqttnio-password")),
            identifier: "connectWithUsernameAndPassword",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Connect with Wrong Username and Password")
    func connectWithWrongUsernameAndPassword() async throws {
        await #expect(throws: MQTTError.connectionError(.notAuthorized)) {
            try await MQTTConnection.withConnection(
                address: .hostname(Self.hostname, port: 1884),
                configuration: .init(authentication: .init(userName: "wrong", password: "wrong")),
                identifier: "connectWithWrongUsernameAndPassword",
                logger: self.logger
            ) { connection in
                try await connection.ping()
            }
        }
    }

    @Test("Connect with WebSocket")
    func webSocketConnect() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname, port: 8080),
            configuration: .init(webSocketConfiguration: .init()),
            identifier: "webSocketConnect",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Suite(.serialized)
    struct TLS {
        static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"

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

        let logger: Logger = {
            var logger = Logger(label: "IntegrationTLSTests")
            logger.logLevel = .trace
            return logger
        }()

        @Test("Connect with TLS")
        func tlsConnect() async throws {
            try await MQTTConnection.withConnection(
                address: .hostname(Self.hostname, port: 8883),
                configuration: .init(tls: .enable(self.getTLSConfiguration(), tlsServerName: "soto.codes")),
                identifier: "tlsConnect",
                eventLoop: Self.eventLoopGroupSingleton.any(),
                logger: self.logger
            ) { connection in
                try await connection.ping()
            }
        }

        @Test("Connect with WebSocket and TLS")
        func webSocketAndTLSConnect() async throws {
            try await MQTTConnection.withConnection(
                address: .hostname(Self.hostname, port: 8081),
                configuration: .init(
                    timeout: .seconds(5),
                    tls: .enable(self.getTLSConfiguration(), tlsServerName: "soto.codes"),
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
            try await MQTTConnection.withConnection(
                address: .hostname(Self.hostname, port: 8883),
                configuration: .init(
                    tls: .enable(
                        .ts(
                            .init(
                                trustRoots: .der(Self.rootPath + "/mosquitto/certs/ca.der"),
                                clientIdentity: .p12(
                                    filename: Self.rootPath + "/mosquitto/certs/client.p12",
                                    password: "MQTTNIOClientCertPassword"
                                )
                            )
                        ),
                        tlsServerName: "soto.codes"
                    )
                ),
                identifier: "tlsConnectFromP12",
                eventLoop: Self.eventLoopGroupSingleton.any(),
                logger: self.logger
            ) { connection in
                try await connection.ping()
            }
        }
        #endif

        func getTLSConfiguration(
            withTrustRoots: Bool = true,
            withClientKey: Bool = true
        ) throws -> MQTTConnectionConfiguration.TLS.Configuration {
            #if os(Linux)
            let rootCertificate = try NIOSSLCertificate.fromPEMFile(Self.rootPath + "/mosquitto/certs/ca.pem")
            let certificate = try NIOSSLCertificate.fromPEMFile(Self.rootPath + "/mosquitto/certs/client.pem")
            let privateKey = try NIOSSLPrivateKey(file: Self.rootPath + "/mosquitto/certs/client.key", format: .pem)
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.trustRoots = withTrustRoots ? .certificates(rootCertificate) : .default
            tlsConfiguration.certificateChain = withClientKey ? certificate.map { .certificate($0) } : []
            tlsConfiguration.privateKey = withClientKey ? .privateKey(privateKey) : nil
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
                trustRoots: withTrustRoots ? trustRootCertificates : nil,
                clientIdentity: withClientKey ? identity : nil
            )
            return .ts(tlsConfiguration)
            #endif
        }
    }

    @Test("Connect with Unix Domain Socket")
    func unixDomainSocketConnect() async throws {
        try await MQTTConnection.withConnection(
            address: .unixDomainSocket(path: Self.rootPath + "/mosquitto/socket/mosquitto.sock"),
            identifier: "unixDomainSocketConnect",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Publish", arguments: MQTTQoS.allCases)
    func publish(qos: MQTTQoS) async throws {
        try await MQTTConnection.withConnection(
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

    @Test("Send PINGREQ")
    func sendPingreq() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "sendPingreq",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Server-Initiated Disconnection")
    func serverDisconnect() async throws {
        struct MQTTForceDisconnectMessage: MQTTPacket {
            var type: MQTTPacketType { .PUBLISH }
            var description: String { "FORCEDISCONNECT" }

            func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
                // writing publish header with no content will cause a disconnect from the server
                byteBuffer.writeInteger(UInt8(0x30))
                byteBuffer.writeInteger(UInt8(0x0))
            }

            static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
                throw InternalError.notImplemented
            }
        }

        await #expect(throws: MQTTError.serverClosedConnection) {
            try await MQTTConnection.withConnection(
                address: .hostname(Self.hostname),
                identifier: "serverDisconnect",
                logger: self.logger
            ) { connection in
                try await connection.sendMessage(MQTTForceDisconnectMessage()) { _ in true }
            }
        }
    }

    @Test("Publish with Retain Flag")
    func publishRetain() async throws {
        let payloadString =
            #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname, port: 8080),
            configuration: .init(webSocketConfiguration: .init()),
            identifier: "publishRetain",
            logger: self.logger
        ) { connection in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await connection.subscribe(to: [.init(topicFilter: "testMQTTPublishRetain", qos: .atLeastOnce)]) { subscription in
                        try await confirmation("publishRetain") { receivedMessage in
                            for try await message in subscription {
                                var buffer = message.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                #expect(string == payloadString)
                                receivedMessage()
                                return
                            }
                        }
                    }
                }

                group.addTask {
                    try await connection.publish(to: "testMQTTPublishRetain", payload: payload, qos: .atLeastOnce, retain: true)
                }

                try await group.waitForAll()
            }
        }
    }

    @Test("Publish to Client")
    func publishToClient() async throws {
        let payloadString =
            #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        try await withThrowingTaskGroup { group in
            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname, port: 8080),
                    configuration: .init(webSocketConfiguration: .init()),
                    identifier: "publishToClient_subscriber",
                    logger: self.logger
                ) { connection in
                    try await connection.subscribe(
                        to: [
                            .init(topicFilter: "testAtLeastOnce", qos: .atLeastOnce),
                            .init(topicFilter: "testExactlyOnce", qos: .exactlyOnce),
                        ]
                    ) { subscription in
                        try await confirmation("publishToClient", expectedCount: 2) { receivedMessage in
                            var count = 0
                            for try await message in subscription {
                                var buffer = message.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                #expect(string == payloadString)
                                #expect(
                                    !message.properties.contains { if case .subscriptionIdentifier = $0 { true } else { false } },
                                    "Subscription Identifier property should not be present in v3.1.1 messages"
                                )
                                receivedMessage()
                                count += 1
                                if count == 2 { return }
                            }
                        }
                    }
                }
            }

            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname, port: 8080),
                    configuration: .init(webSocketConfiguration: .init()),
                    identifier: "publishToClient_publisher",
                    logger: self.logger
                ) { connection in
                    try await Task.sleep(for: .seconds(1))
                    try await connection.publish(to: "testAtLeastOnce", payload: payload, qos: .atLeastOnce)
                    try await connection.publish(to: "testExactlyOnce", payload: payload, qos: .exactlyOnce)
                }
            }

            try await group.waitForAll()
        }
    }

    @Test("Publish Large Payload to Client")
    func publishLargePayloadToClient() async throws {
        let payloadSize = 65537
        let payloadData = Data(count: payloadSize)
        let payload = ByteBufferAllocator().buffer(data: payloadData)

        try await withThrowingTaskGroup { group in
            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    identifier: "publishLargePayloadToClient_subscriber",
                    logger: self.logger
                ) { connection in
                    try await connection.subscribe(to: [.init(topicFilter: "testLargeAtLeastOnce", qos: .atLeastOnce)]) { subscription in
                        try await confirmation("publishLargePayloadToClient") { receivedMessage in
                            for try await message in subscription {
                                var buffer = message.payload
                                let data = buffer.readData(length: buffer.readableBytes)
                                #expect(data == payloadData)
                                receivedMessage()
                                return
                            }
                        }
                    }
                }
            }

            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    identifier: "publishLargePayloadToClient_publisher",
                    logger: self.logger
                ) { connection in
                    try await Task.sleep(for: .seconds(1))
                    try await connection.publish(to: "testLargeAtLeastOnce", payload: payload, qos: .atLeastOnce)
                }
            }

            try await group.waitForAll()
        }
    }

    @Test("Subscribe to All Topics", .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil))
    func subscribeAll() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname("test.mosquitto.org"),
            identifier: "subscribeAll",
            logger: self.logger
        ) { connection in
            try await connection.subscribe(to: [.init(topicFilter: "#", qos: .exactlyOnce)]) { subscription in
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    #if os(macOS)
    @Test("Connect with Raw IP Address")
    func rawIPConnect() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname("127.0.0.1"),
            identifier: "rawIPConnect",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }
    #endif

    @Test("Verify Packet ID Increments")
    func packetID() async throws {
        try await MQTTConnection.withConnection(
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

    @Test("Subscribe to Multi-level Wildcard")
    func multiLevelWildcard() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "multiLevelWildcard",
            logger: self.logger
        ) { connection in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await confirmation("multiLevelWildcard", expectedCount: 2) { receivedMessage in
                        try await connection.subscribe(to: [.init(topicFilter: "multiLevel/home/kitchen/#", qos: .atLeastOnce)]) { subscription in
                            var count = 0
                            for try await message in subscription {
                                var buffer = message.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                #expect(string == "test")
                                receivedMessage()
                                count += 1
                                if count == 2 { return }
                            }
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    try await connection.publish(to: "multiLevel/home/kitchen/temperature", payload: ByteBuffer(string: "test"), qos: .atLeastOnce)
                    try await connection.publish(
                        to: "multiLevel/home/livingroom/temperature",
                        payload: ByteBuffer(string: "error"),
                        qos: .atLeastOnce
                    )
                    try await connection.publish(to: "multiLevel/home/kitchen/humidity", payload: ByteBuffer(string: "test"), qos: .atLeastOnce)
                }

                try await group.waitForAll()
            }
        }
    }

    @Test("Subscribe to Single Level Wildcard")
    func singleLevelWildcard() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "singleLevelWildcard",
            logger: self.logger
        ) { connection in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await confirmation("singleLevelWildcard", expectedCount: 2) { receivedMessage in
                        try await connection.subscribe(to: [.init(topicFilter: "singleLevel/home/+/temperature", qos: .atLeastOnce)]) {
                            subscription in
                            var count = 0
                            for try await message in subscription {
                                var buffer = message.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                #expect(string == "test")
                                receivedMessage()
                                count += 1
                                if count == 2 { return }
                            }
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    try await connection.publish(
                        to: "singleLevel/home/livingroom/temperature",
                        payload: ByteBuffer(string: "test"),
                        qos: .atLeastOnce
                    )
                    try await connection.publish(to: "singleLevel/home/garden/humidity", payload: ByteBuffer(string: "error"), qos: .atLeastOnce)
                    try await connection.publish(to: "singleLevel/home/kitchen/temperature", payload: ByteBuffer(string: "test"), qos: .atLeastOnce)
                }

                try await group.waitForAll()
            }
        }
    }

    /// Test that if a message matches multiple topic filters of a single subscription,
    /// the subscription receives as many copies of the message as there are matching topic filters.
    @Test("Overlapping Subscriptions")
    func overlappingSubscriptions() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "overlappingSubscriptions",
            logger: self.logger
        ) { connection in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await confirmation("overlappingSubscriptions", expectedCount: 2) { receivedMessage in
                        try await connection.subscribe(to: [
                            .init(topicFilter: "overlapping/home/+/temperature", qos: .atLeastOnce),
                            .init(topicFilter: "overlapping/home/kitchen/#", qos: .atLeastOnce),
                        ]) { subscription in
                            var count = 0
                            for try await message in subscription {
                                var buffer = message.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                #expect(string == "test")
                                receivedMessage()
                                count += 1
                                if count == 2 { return }
                            }
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    try await connection.publish(to: "overlapping/home/kitchen/temperature", payload: ByteBuffer(string: "test"), qos: .atLeastOnce)
                }

                try await group.waitForAll()
            }
        }
    }

    @Test("Cancellation")
    func cancellation() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "cancellation",
            logger: self.logger
        ) { connection in
            await withThrowingTaskGroup { group in
                group.addTask {
                    await #expect(throws: MQTTError.cancelledTask) {
                        try await connection.subscribe(to: [.init(topicFilter: "cancellation", qos: .exactlyOnce)]) { subscription in
                            for try await _ in subscription {
                                Issue.record("Should not receive messages")
                            }
                        }
                    }
                }
                group.cancelAll()
            }
        }
    }

    @Test("Already Cancelled")
    func alreadyCancelled() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "alreadyCancelled",
            logger: self.logger
        ) { connection in
            await withThrowingTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask {
                    await #expect(throws: MQTTError.cancelledTask) {
                        try await connection.subscribe(to: [.init(topicFilter: "alreadyCancelled", qos: .exactlyOnce)]) { subscription in
                            for try await _ in subscription {
                                Issue.record("Should not receive messages")
                            }
                        }
                    }
                }
            }
        }
    }

    let logger: Logger = {
        var logger = Logger(label: "IntegrationTests")
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
}

extension MQTTError: Equatable {
    public static func == (lhs: MQTTError, rhs: MQTTError) -> Bool {
        switch (lhs, rhs) {
        case (.failedToConnect, .failedToConnect),
            (.connectionClosed, .connectionClosed),
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
            (.serverDisconnection, .serverDisconnection),
            (.cancelledTask, .cancelledTask):
            true
        case (.connectionError(let lhsValue), .connectionError(let rhsValue)):
            lhsValue == rhsValue
        case (.reasonError(let lhsValue), .reasonError(let rhsValue)):
            lhsValue == rhsValue
        case (.versionMismatch(let expectedLHS, let actualLHS), .versionMismatch(let expectedRHS, let actualRHS)):
            expectedLHS == expectedRHS && actualLHS == actualRHS
        case (.invalidTopicFilter(let lhsValue), .invalidTopicFilter(let rhsValue)):
            lhsValue == rhsValue
        default:
            false
        }
    }
}
