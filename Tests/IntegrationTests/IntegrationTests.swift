//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import NIOPosix
import Synchronization
import Testing

@testable import MQTTNIO

#if canImport(Network)
import NIOTransportServices
#endif
#if os(macOS) || os(Linux) || os(Android)
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
            logger: Logger(label: #function).withLogLevel(.trace)
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Close On Failed Connect Send")
    func closeOnFailedConnectSend() async throws {
        await withThrowingTaskGroup { group in
            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    identifier: "closeOnFailedConnectPacketSend",
                    logger: Logger(label: #function).withLogLevel(.trace)
                ) { connection in
                }
            }
            group.cancelAll()
            await #expect(throws: MQTTError.cancelledTask) {
                try await group.next()
            }
        }
    }

    @Test("Keep Alive Ping")
    func keepAlivePing() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(pingConfiguration: .pingInterval(.seconds(2))),
            identifier: "keepAlivePing",
            logger: Logger(label: #function).withLogLevel(.trace)
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
            logger: Logger(label: #function).withLogLevel(.trace)
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
                logger: Logger(label: #function).withLogLevel(.trace)
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
            logger: Logger(label: #function).withLogLevel(.trace)
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

        static var eventLoopGroupSingleton: any EventLoopGroup {
            #if os(Linux) || os(Android)
            MultiThreadedEventLoopGroup.singleton
            #else
            // Return TS Eventloop for non-Linux builds, as we use TS TLS
            NIOTSEventLoopGroup.singleton
            #endif
        }

        @Test("Connect with TLS")
        func tlsConnect() async throws {
            try await MQTTConnection.withConnection(
                address: .hostname(Self.hostname, port: 8883),
                configuration: .init(tls: .enable(self.getTLSConfiguration(), tlsServerName: "soto.codes")),
                identifier: "tlsConnect",
                eventLoop: Self.eventLoopGroupSingleton.any(),
                logger: Logger(label: #function).withLogLevel(.trace)
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
                logger: Logger(label: #function).withLogLevel(.trace)
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
                logger: Logger(label: #function).withLogLevel(.trace)
            ) { connection in
                try await connection.ping()
            }
        }
        #endif

        func getTLSConfiguration(
            withTrustRoots: Bool = true,
            withClientKey: Bool = true
        ) throws -> MQTTConnectionConfiguration.TLS.Configuration {
            #if os(Linux) || os(Android)
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
            logger: Logger(label: #function).withLogLevel(.trace)
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Publish", arguments: MQTTQoS.allCases)
    func publish(qos: MQTTQoS) async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "publishQoS\(qos.rawValue)",
            logger: Logger(label: #function).withLogLevel(.trace)
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
            logger: Logger(label: #function).withLogLevel(.trace)
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Server-Initiated Disconnection")
    func serverDisconnect() async throws {
        await #expect(throws: MQTTError.serverClosedConnection) {
            try await MQTTConnection.withConnection(
                address: .hostname(Self.hostname),
                identifier: "serverDisconnect",
                logger: Logger(label: #function).withLogLevel(.trace)
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
            logger: Logger(label: #function).withLogLevel(.trace)
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
                    logger: Logger(label: #function).withLogLevel(.trace)
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
                    logger: Logger(label: #function).withLogLevel(.trace)
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
                    logger: Logger(label: #function).withLogLevel(.trace)
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
                    logger: Logger(label: #function).withLogLevel(.trace)
                ) { connection in
                    try await Task.sleep(for: .seconds(1))
                    try await connection.publish(to: "testLargeAtLeastOnce", payload: payload, qos: .atLeastOnce)
                }
            }

            try await group.waitForAll()
        }
    }

    @Test("Session Present")
    func sessionPresent() async throws {
        // First connection without a `MQTTSession` (and with `cleanSession` automatically set to true)
        // `sessionPresent` should be false as this is the first connection with this client identifier
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "sessionPresent",
            logger: Logger(label: #function).withLogLevel(.trace)
        ) { connection in
            try await connection.ping()
        }

        let session = MQTTSession(clientID: "sessionPresent", logger: Logger(label: #function).withLogLevel(.trace))

        // Second connection with a `MQTTSession` with same client identifier (and `cleanSession` automatically set to false)
        // `sessionPresent` should be false as previous connection was with `cleanSession` true
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            session: session,
            logger: Logger(label: #function).withLogLevel(.trace)
        ) { connection, sessionPresent in
            #expect(sessionPresent == false)
            try await connection.ping()
        }

        // Third connection with same `MQTTSession`
        // `sessionPresent` should be true
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            session: session,
            logger: Logger(label: #function).withLogLevel(.trace)
        ) { connection, sessionPresent in
            #expect(sessionPresent == true)
            try await connection.ping()
        }
    }

    @Test("Subscribe to All Topics", .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil))
    func subscribeAll() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname("broker.hivemq.com"),
            identifier: "subscribeAll",
            logger: Logger(label: #function).withLogLevel(.trace)
        ) { connection in
            try await connection.subscribe(to: [.init(topicFilter: "test/#", qos: .exactlyOnce)]) { subscription in
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
            logger: Logger(label: #function).withLogLevel(.trace)
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
            logger: Logger(label: #function).withLogLevel(.trace)
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

    @Test("Subscribe to Multi-level Wildcard")
    func multiLevelWildcard() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "multiLevelWildcard",
            logger: Logger(label: #function).withLogLevel(.trace)
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
            logger: Logger(label: #function).withLogLevel(.trace)
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
            logger: Logger(label: #function).withLogLevel(.trace)
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
            logger: Logger(label: #function).withLogLevel(.trace)
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
            logger: Logger(label: #function).withLogLevel(.trace)
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

    @Test("Inflight")
    func inflight() async throws {
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    identifier: "inflight_subscriber",
                    logger: Logger(label: #function).withLogLevel(.trace)
                ) { connection in
                    try await connection.subscribe(to: [.init(topicFilter: "testInflight", qos: .exactlyOnce)]) { subscription in
                        for try await message in subscription {
                            #expect(message.payload.readableBytes == 4)
                            return
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: .milliseconds(500))
                let session = MQTTSession(clientID: "inflight_publisher", logger: Logger(label: #function).withLogLevel(.trace))

                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: Logger(label: #function).withLogLevel(.trace)
                ) { connection, sessionPresent in
                    async let _ = connection.publish(to: "testInflight", payload: ByteBuffer(string: "test"), qos: .exactlyOnce)
                    connection.close()
                }

                #expect(try session.storage.borrow { $0.inflight.packets.count } > 0)

                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: Logger(label: #function).withLogLevel(.trace)
                ) { connection, sessionPresent in
                    try await connection.ping()
                }

                #expect(try session.storage.borrow { $0.inflight.packets.count } == 0)
            }

            try await group.waitForAll()
        }
    }

    @Test("Multiple Connections with Same Session")
    func multipleConnectionsWithSameSession() async throws {
        let session = MQTTSession(clientID: "multipleConnectionsWithSameSession", logger: Logger(label: #function).withLogLevel(.trace))

        await #expect(throws: MQTTError.alreadyConnectedWithSession) {
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await MQTTConnection.withConnection(
                        address: .hostname(Self.hostname),
                        session: session,
                        logger: Logger(label: #function).withLogLevel(.trace)
                    ) { connection, sessionPresent in
                        try await connection.subscribe(to: [.init(topicFilter: "multipleConnWithSession1", qos: .atMostOnce)]) { subscription in
                            for try await _ in subscription {}
                        }
                    }
                }

                group.addTask {
                    try await MQTTConnection.withConnection(
                        address: .hostname(Self.hostname),
                        session: session,
                        logger: Logger(label: #function).withLogLevel(.trace)
                    ) { connection, sessionPresent in
                        try await connection.subscribe(to: [.init(topicFilter: "multipleConnWithSession2", qos: .atMostOnce)]) { subscription in
                            for try await _ in subscription {}
                        }
                    }
                }

                try await group.next()
            }
        }
    }

    @Test("Subscribe with Session before Connection")
    func subscribeWithSessionBeforeConnection() async throws {
        // Make an initial connection with `cleanSession` to clear any existing session state
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "subscribeWithSessionBeforeConnection",
            logger: Logger(label: #function).withLogLevel(.trace)
        ) { connection in
            try await connection.ping()
        }

        let session = MQTTSession(clientID: "subscribeWithSessionBeforeConnection", logger: Logger(label: #function).withLogLevel(.trace))

        await withThrowingTaskGroup { group in
            group.addTask {
                try await session.subscribe(to: [.init(topicFilter: "subscribeWithSessionBeforeConnection", qos: .atLeastOnce)]) { subscription in
                    var iterator = subscription.makeAsyncIterator()
                    try #expect(await (iterator.next()?.payload).map { String(buffer: $0) } == "test")
                    try #expect(await (iterator.next()?.payload).map { String(buffer: $0) } == "test2")
                }
            }

            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: Logger(label: #function).withLogLevel(.trace)
                ) { connection, sessionPresent in
                    // Wait for the subscription to be established before publishing
                    try await Task.sleep(for: .milliseconds(100))

                    #expect(!sessionPresent)
                    try await connection.publish(to: "subscribeWithSessionBeforeConnection", payload: ByteBuffer(string: "test"), qos: .atLeastOnce)
                }

                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: Logger(label: #function).withLogLevel(.trace)
                ) { connection, sessionPresent in
                    #expect(sessionPresent)
                    try await connection.publish(to: "subscribeWithSessionBeforeConnection", payload: ByteBuffer(string: "test2"), qos: .atLeastOnce)
                }
            }
        }
    }

    @Test("Subscribe with Session after Connection")
    func subscribeWithSessionAfterConnection() async throws {
        let logger = Logger(label: #function).withLogLevel(.trace)

        // Make an initial connection with `cleanSession` to clear any existing session state
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "subscribeWithSessionAfterConnection",
            logger: logger
        ) { connection in
            try await connection.ping()
        }

        let session = MQTTSession(clientID: "subscribeWithSessionAfterConnection", logger: logger)

        let (stream, continuation) = AsyncStream<Void>.makeStream()

        await withThrowingTaskGroup { group in
            group.addTask {
                // Wait for the connection task to signal that the connection has been established before subscribing
                await stream.first { _ in true }

                try await session.subscribe(to: [.init(topicFilter: "subscribeWithSessionAfterConnection", qos: .atLeastOnce)]) { subscription in
                    var iterator = subscription.makeAsyncIterator()
                    try #expect(await (iterator.next()?.payload).map { String(buffer: $0) } == "test")
                    try #expect(await (iterator.next()?.payload).map { String(buffer: $0) } == "test2")
                }
            }

            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: logger
                ) { connection, sessionPresent in
                    #expect(!sessionPresent)

                    // Signal to the subscription task that the connection has been established and it can subscribe
                    continuation.yield()
                    // Wait for the subscription to be established before publishing
                    try await Task.sleep(for: .milliseconds(100))

                    try await connection.publish(to: "subscribeWithSessionAfterConnection", payload: ByteBuffer(string: "test"), qos: .atLeastOnce)
                }

                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: logger
                ) { connection, sessionPresent in
                    #expect(sessionPresent)
                    try await connection.publish(to: "subscribeWithSessionAfterConnection", payload: ByteBuffer(string: "test2"), qos: .atLeastOnce)
                }
            }
        }
    }

    @Test("Close Subscriptions on No Session Present")
    func closeSubscriptionsNoSessionPresent() async throws {
        // Make an initial connection with `cleanSession` to clear any existing session state
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "closeSubscriptionsNoSessionPresent",
            logger: Logger(label: #function).withLogLevel(.trace)
        ) { connection in
            try await connection.ping()
        }

        let session = MQTTSession(clientID: "closeSubscriptionsNoSessionPresent", logger: Logger(label: #function).withLogLevel(.trace))

        await withThrowingTaskGroup { group in
            group.addTask {
                _ = await #expect(throws: MQTTError.noSessionPresent) {
                    try await session.subscribe(to: [.init(topicFilter: "closeSubscriptionsNoSessionPresent", qos: .atLeastOnce)]) { subscription in
                        for try await _ in subscription {}
                    }
                }
            }

            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: Logger(label: #function).withLogLevel(.trace)
                ) { connection, sessionPresent in
                    // Wait for the subscription to be established before publishing
                    try await Task.sleep(for: .milliseconds(100))

                    // First connection with the session
                    #expect(!sessionPresent)
                    try await connection.publish(to: "closeSubscriptionsNoSessionPresent", payload: ByteBuffer(string: "test"), qos: .atLeastOnce)
                }

                // Make a connection with `cleanSession` to clear existing session state
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    identifier: "closeSubscriptionsNoSessionPresent",
                    logger: Logger(label: #function).withLogLevel(.trace)
                ) { connection in
                    try await connection.ping()
                }

                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: Logger(label: #function).withLogLevel(.trace)
                ) { connection, sessionPresent in
                    // The previous connection was with `cleanSession` true,
                    // so even though this connection is with the same session,
                    // `sessionPresent` should be false and the subscriptions should be closed
                    #expect(!sessionPresent)
                    try await connection.ping()
                }
            }
        }
    }

    @Test("Close Subscriptions")
    func closeSubscriptions() async throws {
        // Make an initial connection with `cleanSession` to clear any existing session state
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "closeSubscriptions",
            logger: Logger(label: #function).withLogLevel(.trace)
        ) { connection in
            try await connection.ping()
        }

        let logger = Logger(label: #function).withLogLevel(.trace)

        let session = MQTTSession(clientID: "closeSubscriptions", logger: logger)

        await withThrowingTaskGroup { group in
            let (stream, continuation) = AsyncStream<Void>.makeStream()

            group.addTask {
                _ = await #expect(throws: Never.self) {
                    // Open a subscription with the session that won't throw an error when the connection is closed
                    try await session.subscribe(to: [.init(topicFilter: "sessionSub", qos: .atLeastOnce)]) { subscription in
                        await stream.first { _ in true }
                    }
                }
            }

            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: logger
                ) { connection, sessionPresent in
                    try await withThrowingTaskGroup { group in
                        group.addTask {
                            _ = await #expect(throws: MQTTError.self) {
                                // Open a subscription with the connection that will throw an error when the connection is closed
                                try await connection.subscribe(to: [.init(topicFilter: "connectionSub", qos: .atLeastOnce)]) { subscription in
                                    for try await _ in subscription {}
                                }
                            }
                        }

                        // Wait for the session subscription to be setup
                        try await Task.sleep(for: .seconds(1))
                        connection.close()
                    }
                }

                // Signal to the session subscription that the connection has been closed
                continuation.yield()
            }
        }
    }

    @Test("Failed Subscription on Session")
    func failedSubscriptionOnSession() async throws {
        let logger = Logger(label: #function).withLogLevel(.trace)

        // Make an initial connection with `cleanSession` to clear any existing session state
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "failedSubscriptionOnSession",
            logger: logger
        ) { connection in
            try await connection.ping()
        }

        let session = MQTTSession(clientID: "failedSubscriptionOnSession", logger: logger)

        await withThrowingTaskGroup { group in
            group.addTask {
                _ = await #expect(throws: MQTTError.serverClosedConnection) {
                    // Subscribe with an invalid topic filter to cause the server to close the connection
                    try await session.subscribe(to: [.init(topicFilter: "", qos: .atLeastOnce)]) { subscription in
                        for try await _ in subscription {}
                    }
                }
            }

            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: logger
                ) { connection, sessionPresent in
                    #expect(!sessionPresent)
                    try await connection.ping()
                }
            }
        }
    }

    @Test("Connection Subscription Cleanup", arguments: [true, false])
    func connectionSubscriptionCleanup(clientClose: Bool) async throws {
        let logger = Logger(label: #function).withLogLevel(.trace)
        let identifier = "connectionSubscriptionCleanup_" + (clientClose ? "clientClose" : "forceDisconnect")

        // Make an initial connection with `cleanSession` to clear any existing session state
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: identifier,
            logger: logger
        ) { connection in
            try await connection.ping()
        }

        let session = MQTTSession(clientID: identifier, logger: logger)

        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            session: session,
            logger: logger
        ) { connection, sessionPresent in
            #expect(!sessionPresent)

            await withThrowingTaskGroup { group in
                // Used to signal when the subscription has been established
                let (stream, continuation) = AsyncStream<Void>.makeStream()

                group.addTask {
                    try await connection.subscribe(to: [.init(topicFilter: identifier, qos: .atLeastOnce)]) { subscription in
                        // Signal that the subscription has been established
                        continuation.yield()
                        for try await _ in subscription {}
                    }
                }

                // Wait for the subscription to be setup
                await stream.first { _ in true }

                await #expect(connection.session.subscriptions.subscriptionIDMap.count == 1)

                if clientClose {
                    connection.close()
                } else {
                    _ = try? await connection.sendMessage(MQTTForceDisconnectMessage()) { _ in true }
                }

                await #expect(throws: MQTTError.self) {
                    try await group.next()
                }
            }
        }
        #expect(try session.storage.borrow { $0.subscriptions.subscriptionIDMap.isEmpty })
    }

    @Test("Wait Until No Active Subscriptions")
    func waitUntilNoActiveSubscriptions() async throws {
        let logger = Logger(label: "Integration.\(#function)").withLogLevel(.trace)

        // Make an initial connection with `cleanSession` to clear any existing session state
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "waitUntilNoActiveSubscriptions",
            logger: logger
        ) { connection in
            try await connection.ping()
        }

        let session = MQTTSession(clientID: "waitUntilNoActiveSubscriptions", logger: logger)

        try await withThrowingTaskGroup { group in
            let (connectionStream, connectionContinuation) = AsyncStream.makeStream(of: Void.self)
            let (sessionStream, sessionContinuation) = AsyncStream.makeStream(of: Void.self)

            group.addTask {
                // Wait for the connection task to signal that the connection has been established before subscribing
                await connectionStream.first { _ in true }

                try await session.subscribe(to: [.init(topicFilter: "wait/session", qos: .atLeastOnce)]) { subscription in
                    var iterator = subscription.makeAsyncIterator()
                    try #expect(await (iterator.next()?.payload).map { String(buffer: $0) } == "test")
                }
            }

            group.addTask {
                try await MQTTConnection.withConnection(
                    address: .hostname(Self.hostname),
                    session: session,
                    logger: logger
                ) { connection, sessionPresent in
                    #expect(!sessionPresent)

                    // Signal to the subscription task that the connection has been established and it can subscribe
                    connectionContinuation.yield()
                    // Wait for the subscription to be established before publishing
                    try await Task.sleep(for: .milliseconds(100))
                    // Signal that the session subscription is active
                    sessionContinuation.yield()

                    try await withThrowingTaskGroup { connectionGroup in
                        let (publishStream, publishContinuation) = AsyncStream.makeStream(of: Void.self)

                        connectionGroup.addTask {
                            // Wait for `waitUntilNoActiveSubscriptions` to be called
                            try await Task.sleep(for: .milliseconds(100))

                            try await connection.subscribe(to: [.init(topicFilter: "wait/connection", qos: .atLeastOnce)]) { subscription in
                                publishContinuation.yield()
                                var iterator = subscription.makeAsyncIterator()
                                try #expect(await (iterator.next()?.payload).map { String(buffer: $0) } == "test")
                            }
                        }

                        connectionGroup.addTask {
                            await publishStream.first { _ in true }
                            try await connection.publish(to: "wait/session", payload: ByteBuffer(string: "test"), qos: .atLeastOnce)
                            try await connection.publish(to: "wait/connection", payload: ByteBuffer(string: "test"), qos: .atLeastOnce)
                        }

                        connectionGroup.addTask {
                            // Wait until the session subscription is active
                            await sessionStream.first { _ in true }

                            try await connection.waitUntilNoActiveSubscriptions()
                        }

                        try await connectionGroup.waitForAll()
                    }
                }
            }

            try await group.waitForAll()
        }
    }

    @Test("Cancel Active Subscriptions Wait On Close")
    func cancelActiveSubscriptionsWait() async throws {
        let logger = Logger(label: #function).withLogLevel(.trace)

        // Make an initial connection with `cleanSession` to clear any existing session state
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            identifier: "cancelActiveSubscriptionsWait",
            logger: logger
        ) { connection in
            try await connection.ping()
        }

        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        let session = MQTTSession(clientID: "cancelActiveSubscriptionsWait", logger: logger)
        async let _ = session.subscribe(to: [.init(topicFilter: "test", qos: .atLeastOnce)]) { sub in
            for try await _ in sub {
                cont.yield()
            }
        }

        // expect waitUntilNoActiveSubscriptions to throw error immediately as the connection is closed
        await #expect(throws: MQTTError.connectionClosed) {
            try await MQTTConnection.withConnection(
                address: .hostname(Self.hostname),
                session: session,
                logger: logger
            ) { connection, sessionPresent in
                // make sure the subscriptions have been sent before sending a publish
                try await Task.sleep(for: .milliseconds(50))
                try await connection.publish(to: "test", payload: .init(), qos: .atLeastOnce)
                await stream.first { _ in true }
                connection.close()
                await connection.waitOnClose()
                try await connection.waitUntilNoActiveSubscriptions()
            }
        }

        // expect waitUntilNoActiveSubscriptions to throw error when the connection is closed
        await #expect(throws: MQTTError.serverClosedConnection) {
            try await MQTTConnection.withConnection(
                address: .hostname(Self.hostname),
                session: session,
                logger: logger
            ) { connection, sessionPresent in
                try await connection.publish(to: "test", payload: .init(), qos: .atLeastOnce)
                await stream.first { _ in true }
                try await withThrowingTaskGroup { group in
                    group.addTask {
                        try await Task.sleep(for: .milliseconds(50))
                        connection.close()
                    }
                    try await connection.waitUntilNoActiveSubscriptions()
                }
            }
        }

        // expect waitUntilNoActiveSubscriptions to throw error as it has been cancelled
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            session: session,
            logger: logger
        ) { connection, sessionPresent in
            try await connection.publish(to: "test", payload: .init(), qos: .atLeastOnce)
            await stream.first { _ in true }
            let (stream2, cont2) = AsyncStream.makeStream(of: Void.self)
            await withThrowingTaskGroup { group in
                group.addTask {
                    cont2.yield()
                    await #expect(throws: CancellationError.self) {
                        try await connection.waitUntilNoActiveSubscriptions()
                    }
                }
                await stream2.first { _ in true }
                group.cancelAll()
            }
        }
    }

    static let rootPath = #filePath
        .split(separator: "/", omittingEmptySubsequences: false)
        .dropLast(3)
        .joined(separator: "/")

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
}

extension MQTTConnection {
    /// Test helper to get session
    var session: MQTTSessionStorage { self.channelHandler.session }
}
