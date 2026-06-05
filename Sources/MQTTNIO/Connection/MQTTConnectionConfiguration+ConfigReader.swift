//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

public import Configuration
import HTTPTypes
import NIOCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Network)
import NIOTransportServices
#endif
#if os(macOS) || os(Linux) || os(Android)
import NIOSSL
#endif

extension MQTTConnectionConfiguration {
    /// Creates a new MQTT connection configuration using values from the provided reader.
    ///
    /// ## Configuration keys
    /// - `version` (string, optional, default: `"v3_1_1"`): Version of the MQTT server.
    /// - `will.topicName` (string, optional): Topic Name of the Will Message.
    /// - `will.payload` (bytes, optional): Payload of the Will Message.
    /// - `will.qos` (int, optional): QoS level of the Will Message.
    /// - `will.retain` (bool, optional, default: `false`): Specifies if the Will Message is to be retained when it is published.
    /// - `keepAliveInterval` (int, optional, default: `90`): MQTT keep alive period, in seconds.
    /// - `ping` (int/string, optional): Configuration for sending `PINGREQ` messages.
    ///     If the value is `"disable"`, the ping configuration will be ``MQTTConnectionConfiguration/PingConfiguration/disable``.
    ///     If the value is an integer, that will be the amount of seconds passed to ``MQTTConnectionConfiguration/PingConfiguration/pingInterval(_:)``.
    ///     For any other value, or if there's no value, the ping configuration will be ``MQTTConnectionConfiguration/PingConfiguration/useServerKeepAlive``.
    /// - `connectTimeout` (int, optional, default: `10`): Timeout for connecting to server, in seconds.
    /// - `timeout` (int, optional): Timeout for server ACK responses.
    /// - `userName` (string, optional): The user identifier used to authenticate against a secured MQTT server.
    /// - `password` (string, optional): The password used to authenticate against a secured MQTT server.
    /// - `tls.config` (string, optional): Whether to use `NIOSSL` or `NIOTransportServices`.
    /// - `tls.certificateChain` (string, optional): TLS certificate chain in PEM format.
    /// - `tls.privateKey` (string, optional): TLS private key in PEM format.
    /// - `tls.trustRoots` (string, optional): TLS trust roots in PEM format.
    /// - `tls.serverName` (string, optional): Optional server name for SNI (Server Name Indication).
    /// - `webSocket.urlPath` (string, optional): The URL path to use when establishing the WebSocket connection.
    /// - `webSocket.maxFrameSize` (int, optional): The maximum frame size for the WebSocket connection.
    /// - `webSocket.initialRequestHeaders` (string array, optional): Initial HTTP headers to include in the WebSocket handshake request.
    ///     The string must be in the `<key>:<value>` format.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    public init(config: ConfigReader) {
        switch config.string(forKey: "version") {
        case "v5_0", "v5", "5_0", "5", "v5.0", "5.0":
            self.versionConfiguration = .v5_0(will: try? .init(config: config))
        case .none, .some:
            self.versionConfiguration = .v3_1_1(will: try? .init(config: config))
        }
        self.keepAliveInterval = config.int(forKey: "keepAliveInterval", as: Duration.self, default: .seconds(90))
        self.pingConfiguration = .init(config: config)
        self.connectTimeout = config.int(forKey: "connectTimeout", as: Duration.self, default: .seconds(10))
        self.timeout = config.int(forKey: "timeout", as: Duration.self)
        self.userName = config.string(forKey: "userName")
        self.password = config.string(forKey: "password", isSecret: true)
        self.tls = (try? .init(config: config)) ?? .disable
        self.webSocketConfiguration = .init(config: config)
    }
}

extension MQTTQoS: ExpressibleByConfigInt {
    public init?(configInt: Int) { self.init(rawValue: UInt8(configInt)) }
    public var configInt: Int { Int(self.rawValue) }
}

extension MQTTConnectionConfiguration.VersionConfiguration.WillMessageV311 {
    /// Creates a new Will Message for MQTT v3.1.1 using values from the provided reader.
    ///
    /// ## Configuration keys
    /// - `will.topicName` (string): Topic Name of the Will Message.
    /// - `will.payload` (bytes): Payload of the Will Message.
    /// - `will.qos` (int): QoS level of the Will Message.
    /// - `will.retain` (bool, optional, default: `false`): Specifies if the Will Message is to be retained when it is published.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    init(config: ConfigReader) throws {
        let willConfig = config.scoped(to: "will")
        self.init(
            topicName: try willConfig.requiredString(forKey: "topicName"),
            payload: .init(bytes: try willConfig.requiredBytes(forKey: "payload")),
            qos: try willConfig.requiredInt(forKey: "qos", as: MQTTQoS.self),
            retain: willConfig.bool(forKey: "retain", default: false)
        )
    }
}

extension MQTTConnectionConfiguration.VersionConfiguration.WillMessageV5 {
    /// Creates a new Will Message for MQTT v5.0 using values from the provided reader.
    ///
    /// ## Configuration keys
    /// - `will.topicName` (string): Topic Name of the Will Message.
    /// - `will.payload` (bytes): Payload of the Will Message.
    /// - `will.qos` (int): QoS level of the Will Message.
    /// - `will.retain` (bool, optional, default: `false`): Specifies if the Will Message is to be retained when it is published.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    init(config: ConfigReader) throws {
        let willConfig = config.scoped(to: "will")
        self.init(
            topicName: try willConfig.requiredString(forKey: "topicName"),
            payload: .init(bytes: try willConfig.requiredBytes(forKey: "payload")),
            qos: try willConfig.requiredInt(forKey: "qos", as: MQTTQoS.self),
            retain: willConfig.bool(forKey: "retain", default: false)
        )
    }
}

extension MQTTConnectionConfiguration.PingConfiguration {
    /// Creates a new Ping Configuration using values from the provided reader.
    ///
    /// ## Configuration keys
    /// - `ping` (int/string, optional): Configuration for sending `PINGREQ` messages.
    ///     If the value is `"disable"`, the ping configuration will be ``MQTTConnectionConfiguration/PingConfiguration/disable``.
    ///     If the value is an integer, that will be the amount of seconds passed to ``MQTTConnectionConfiguration/PingConfiguration/pingInterval(_:)``.
    ///     For any other value, or if there's no value, the ping configuration will be ``MQTTConnectionConfiguration/PingConfiguration/useServerKeepAlive``.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    init(config: ConfigReader) {
        if let interval = config.int(forKey: "ping", as: Duration.self) {
            self.base = .pingInterval(interval)
        } else {
            switch config.string(forKey: "ping") {
            case "disable":
                self.base = .disable
            default:
                self.base = .useServerKeepAlive
            }
        }
    }
}

extension MQTTConnectionConfiguration.TLS {
    enum TLSConfigError: Error {
        case incompatibleConfiguration
    }

    /// Creates a new TLS configuration using values from the provided reader.
    ///
    /// ## Configuration keys
    /// - `tls.config` (string, optional): Whether to use `NIOSSL` or `NIOTransportServices`.
    /// - `tls.certificateChain` (string): TLS certificate chain in PEM format.
    /// - `tls.privateKey` (string): TLS private key in PEM format.
    /// - `tls.trustRoots` (string, optional): TLS trust roots in PEM format.
    /// - `tls.serverName` (string, optional): Optional server name for SNI (Server Name Indication).
    ///
    /// - Parameter config: The config reader to read configuration values from.
    ///
    /// - Throws: ``MQTTConnectionConfiguration/TLS/TLSConfigError/incompatibleConfiguration`` if the configuration is not valid or not supported.
    init(config: ConfigReader) throws {
        let tlsConfig = config.scoped(to: "tls")

        let certificateChainPEM = try tlsConfig.requiredString(forKey: "certificateChain")
        let privateKeyPEM = try tlsConfig.requiredString(forKey: "privateKey")
        let trustRootsPEM = tlsConfig.string(forKey: "trustRoots")

        let tlsServerName = tlsConfig.string(forKey: "serverName")

        switch tlsConfig.string(forKey: "config")?.lowercased() {
        #if os(macOS) || os(Linux) || os(Android)
        case "niossl":
            let certificateChain = try NIOSSLCertificate.fromPEMBytes([UInt8](certificateChainPEM.utf8))
            let privateKey = try NIOSSLPrivateKey(bytes: [UInt8](privateKeyPEM.utf8), format: .pem)
            let trustRoots = try trustRootsPEM.map { try NIOSSLCertificate.fromPEMBytes([UInt8]($0.utf8)) }
            var tlsConfiguration = TLSConfiguration.makeServerConfiguration(
                certificateChain: certificateChain.map { .certificate($0) },
                privateKey: .privateKey(privateKey)
            )
            tlsConfiguration.trustRoots = trustRoots.map { .certificates($0) }
            self.base = .enable(.niossl(tlsConfiguration), tlsServerName: tlsServerName)
        #endif
        #if canImport(Network)
        case "ts", "niots", "niotransportservices":
            // TODO: Support NIOTransportServices
            throw TLSConfigError.incompatibleConfiguration
        #endif
        default:
            throw TLSConfigError.incompatibleConfiguration
        }
    }
}

struct ConfigHTTPField: ExpressibleByConfigString {
    let name: HTTPField.Name
    let value: String

    init(name: HTTPField.Name, value: String) {
        self.name = name
        self.value = value
    }

    /// Creates a HTTP header from a configuration string.
    ///
    /// The configuration string must be in the `<key>:<value>` format.
    ///
    /// - Parameter configString: The configuration string to create the HTTP header from.
    init?(configString: String) {
        guard let colonIndex = configString.firstIndex(of: ":") else { return nil }
        guard let name = HTTPField.Name(String(configString[..<colonIndex].trimmingWhitespace())) else { return nil }
        let valueStartIndex = configString.index(after: colonIndex)
        let value = String(configString[valueStartIndex...].trimmingWhitespace())
        self.init(name: name, value: value)
    }

    var description: String { "\(name):\(value)" }
}

extension MQTTConnectionConfiguration.WebSocketConfiguration {
    /// Creates a new WebSocket configuration using values from the provided reader.
    ///
    /// ## Configuration keys
    /// - `webSocket.urlPath` (string, optional): The URL path to use when establishing the WebSocket connection.
    /// - `webSocket.maxFrameSize` (int, optional): The maximum frame size for the WebSocket connection.
    /// - `webSocket.initialRequestHeaders` (string array, optional): Initial HTTP headers to include in the WebSocket handshake request.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    init?(config: ConfigReader) {
        let webSocketConfig = config.scoped(to: "webSocket")
        let urlPath = webSocketConfig.string(forKey: "urlPath")
        let maxFrameSize = webSocketConfig.int(forKey: "maxFrameSize")
        let initialRequestHeaders: HTTPFields?
        if let initialRequestHeadersArray = webSocketConfig.stringArray(forKey: "initialRequestHeaders", as: ConfigHTTPField.self) {
            var headers = HTTPFields()
            for header in initialRequestHeadersArray {
                headers.append(.init(name: header.name, value: header.value))
            }
            initialRequestHeaders = headers
        } else {
            initialRequestHeaders = nil
        }

        if urlPath != nil || maxFrameSize != nil || initialRequestHeaders != nil {
            self.init(
                urlPath: urlPath ?? "/ws",
                maxFrameSize: maxFrameSize ?? 1 << 14,
                initialRequestHeaders: initialRequestHeaders ?? [:]
            )
        } else {
            return nil
        }
    }
}
