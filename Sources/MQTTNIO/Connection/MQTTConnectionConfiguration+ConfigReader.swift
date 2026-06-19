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
    /// ### TLS configuration keys
    /// - `tls.serverName` (string, optional): Optional server name for SNI (Server Name Indication). Valid for both `NIOSSL` and `NIOTransportServices`.
    /// ### NIOTransportServices specific configuration keys (takes precedence over NIOSSL if available)
    /// - `tls.niots.serverName` (string, optional): Name alias for `tls.serverName`. If both `tls.serverName` and `tls.niots.serverName` are provided, the value from `tls.serverName` will be used.
    /// - `tls.niots.privateKey` (string): TLS private key as a file path to a `.p12` file for NIOTransportServices.
    /// - `tls.niots.privateKeyPassword` (string): Password for the TLS private key. Only applicable for NIOTransportServices.
    /// - `tls.niots.trustRoots` (string, optional): TLS trust roots as a file path to a `.der` file for NIOTransportServices.
    /// ### NIOSSL specific configuration keys (used as fallback)
    /// - `tls.certificateChain` (string): TLS certificate chain in PEM format. Only applicable for `NIOSSL`.
    /// - `tls.privateKey` (string): TLS private key, in PEM format for NIOSSL.
    /// - `tls.trustRoots` (string, optional): TLS trust roots, in PEM format for NIOSSL.
    /// ### WebSocket specific configuration keys
    /// - `webSocket.urlPath` (string, optional): The URL path to use when establishing the WebSocket connection.
    /// - `webSocket.maxFrameSize` (int, optional): The maximum frame size for the WebSocket connection.
    /// - `webSocket.initialRequestHeaders` (string array, optional): Initial HTTP headers to include in the WebSocket handshake request.
    ///     The string must be in the `<key>:<value>` format.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    public init(config: ConfigReader) {
        let willConfig = config.scoped(to: "will")
        switch config.string(forKey: "version") {
        case "v5_0", "v5", "5_0", "5", "v5.0", "5.0":
            self.versionConfiguration = .v5_0(will: try? .init(config: willConfig))
        case .none, .some:
            self.versionConfiguration = .v3_1_1(will: try? .init(config: willConfig))
        }
        self.keepAliveInterval = config.int(forKey: "keepAliveInterval", as: Duration.self, default: .seconds(90))
        self.pingConfiguration = .init(config: config)
        self.connectTimeout = config.int(forKey: "connectTimeout", as: Duration.self, default: .seconds(10))
        self.timeout = config.int(forKey: "timeout", as: Duration.self)
        self.userName = config.string(forKey: "userName")
        self.password = config.string(forKey: "password", isSecret: true)
        self.tls = (try? .init(config: config.scoped(to: "tls"))) ?? .disable
        self.webSocketConfiguration = .init(config: config.scoped(to: "webSocket"))
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
    /// - `topicName` (string): Topic Name of the Will Message.
    /// - `payload` (bytes): Payload of the Will Message.
    /// - `qos` (int): QoS level of the Will Message.
    /// - `retain` (bool, optional, default: `false`): Specifies if the Will Message is to be retained when it is published.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    init(config: ConfigReader) throws {
        self.init(
            topicName: try config.requiredString(forKey: "topicName"),
            payload: .init(bytes: try config.requiredBytes(forKey: "payload")),
            qos: try config.requiredInt(forKey: "qos", as: MQTTQoS.self),
            retain: config.bool(forKey: "retain", default: false)
        )
    }
}

extension MQTTConnectionConfiguration.VersionConfiguration.WillMessageV5 {
    /// Creates a new Will Message for MQTT v5.0 using values from the provided reader.
    ///
    /// ## Configuration keys
    /// - `topicName` (string): Topic Name of the Will Message.
    /// - `payload` (bytes): Payload of the Will Message.
    /// - `qos` (int): QoS level of the Will Message.
    /// - `retain` (bool, optional, default: `false`): Specifies if the Will Message is to be retained when it is published.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    init(config: ConfigReader) throws {
        self.init(
            topicName: try config.requiredString(forKey: "topicName"),
            payload: .init(bytes: try config.requiredBytes(forKey: "payload")),
            qos: try config.requiredInt(forKey: "qos", as: MQTTQoS.self),
            retain: config.bool(forKey: "retain", default: false)
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

#if canImport(Network)
extension TSTLSConfiguration {
    /// Creates a new TLS configuration for NIO Transport Services using values from the provided reader.
    ///
    /// ## Configuration keys
    /// - `privateKey` (string): TLS private key, as a file path to a `.p12` file.
    /// - `privateKeyPassword` (string): Password for the TLS private key.
    /// - `trustRoots` (string): TLS trust roots, as a file path to a `.der` file.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    init(config: ConfigReader) throws {
        try self.init(
            trustRoots: .der(config.requiredString(forKey: "trustRoots")),
            clientIdentity: .p12(
                filename: config.requiredString(forKey: "privateKey"),
                password: config.requiredString(forKey: "privateKeyPassword", isSecret: true)
            )
        )
    }
}
#endif

extension MQTTConnectionConfiguration.TLS {
    private enum _TLSConfigError: Error {
        case missingConfiguration
    }

    /// Creates a new TLS configuration using values from the provided reader.
    ///
    /// If the `niots` scoped configuration is present, and NIOTransportServices is available, it will be used as it takes precedence over the `NIOSSL` configuration.
    /// Otherwise, the `NIOSSL` configuration will be used.
    ///
    /// ## Configuration keys
    /// - `serverName` (string, optional): Optional server name for SNI (Server Name Indication). Valid for both `NIOSSL` and `NIOTransportServices`.
    /// ### NIOTransportServices specific configuration keys
    /// - `niots.serverName` (string, optional): Name alias for `serverName`. If both `serverName` and `niots.serverName` are provided, the value from `serverName` will be used.
    /// - `niots.privateKey` (string): TLS private key as a file path to a `.p12` file for NIOTransportServices.
    /// - `niots.privateKeyPassword` (string): Password for the TLS private key. Only applicable for NIOTransportServices.
    /// - `niots.trustRoots` (string, optional): TLS trust roots as a file path to a `.der` file for NIOTransportServices.
    /// ### NIOSSL specific configuration keys (used as fallback)
    /// - `certificateChain` (string): TLS certificate chain in PEM format. Only applicable for `NIOSSL`.
    /// - `privateKey` (string): TLS private key, in PEM format for NIOSSL.
    /// - `trustRoots` (string, optional): TLS trust roots, in PEM format for NIOSSL.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    ///
    /// - Throws: An internal error type if no compatible TLS configuration is found in the provided reader.
    init(config: ConfigReader) throws {
        let tlsServerName = config.string(forKey: "serverName")
        #if canImport(Network)
        let nioTSConfigReader = config.scoped(to: "niots")
        if let tsTLSConfiguration = try? TSTLSConfiguration(config: nioTSConfigReader) {
            self.base = .enable(.ts(tsTLSConfiguration), tlsServerName: tlsServerName ?? nioTSConfigReader.string(forKey: "serverName"))
            return
        }
        #elseif os(macOS) || os(Linux) || os(Android)
        let privateKey = try config.requiredString(forKey: "privateKey")
        let trustRoots = config.string(forKey: "trustRoots")
        let certificateChainPEM = try config.requiredString(forKey: "certificateChain")
        let certificateChain = try NIOSSLCertificate.fromPEMBytes([UInt8](certificateChainPEM.utf8))
        let nioSSLPrivateKey = try NIOSSLPrivateKey(bytes: [UInt8](privateKey.utf8), format: .pem)
        let nioSSLTrustRoots = try trustRoots.map { try NIOSSLCertificate.fromPEMBytes([UInt8]($0.utf8)) }
        var tlsConfiguration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificateChain.map { .certificate($0) },
            privateKey: .privateKey(nioSSLPrivateKey)
        )
        tlsConfiguration.trustRoots = nioSSLTrustRoots.map { .certificates($0) }
        self.base = .enable(.niossl(tlsConfiguration), tlsServerName: tlsServerName)
        #endif
        throw _TLSConfigError.missingConfiguration
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
    /// - `urlPath` (string, optional): The URL path to use when establishing the WebSocket connection.
    /// - `maxFrameSize` (int, optional): The maximum frame size for the WebSocket connection.
    /// - `initialRequestHeaders` (string array, optional): Initial HTTP headers to include in the WebSocket handshake request.
    ///
    /// - Parameter config: The config reader to read configuration values from.
    init?(config: ConfigReader) {
        let urlPath = config.string(forKey: "urlPath")
        let maxFrameSize = config.int(forKey: "maxFrameSize")
        let initialRequestHeaders: HTTPFields?
        if let initialRequestHeadersArray = config.stringArray(forKey: "initialRequestHeaders", as: ConfigHTTPField.self) {
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
