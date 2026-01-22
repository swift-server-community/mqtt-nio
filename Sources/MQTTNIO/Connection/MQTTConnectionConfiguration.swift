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

import NIOCore
import NIOHTTP1

#if os(macOS) || os(Linux)
import NIOSSL
#endif

/// A configuration object that defines how to connect to a MQTT server.
///
/// `MQTTConnectionConfiguration` allows you to customize various aspects of the connection,
/// including authentication credentials, timeouts, and TLS security settings.
///
/// Example usage:
/// ```swift
/// // Basic configuration
/// let config = MQTTConnectionConfiguration()
///
/// // Configuration with authentication
/// let authConfig = MQTTConnectionConfiguration(
///     userName: "user",
///     password: "password"
/// )
///
/// // Configuration with TLS
/// let tlsConfig = TLSConfiguration.makeClientConfiguration()
/// let tlsConfig = MQTTConnectionConfiguration(
///     tls: .enable(.niossl(tlsConfig), tlsServerName: "mqtt.example.com")
/// )
/// ```
public struct MQTTConnectionConfiguration: Sendable {
    /// Version of MQTT server to connect to.
    public enum Version: Sendable {
        case v3_1_1
        case v5_0
    }

    /// Connection configuration for specific MQTT version.
    public enum VersionConfiguration: Sendable {
        case v3_1_1(
            will: (topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool)? = nil
        )
        case v5_0(
            connectProperties: MQTTProperties = .init(),
            disconnectProperties: MQTTProperties = .init(),
            will: (topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool, properties: MQTTProperties)? = nil,
            authWorkflow: MQTTAuthenticator? = nil
        )

        var version: Version {
            switch self {
            case .v3_1_1: .v3_1_1
            case .v5_0: .v5_0
            }
        }
    }

    /// Configuration for TLS (Transport Layer Security) encryption.
    ///
    /// This structure allows you to enable or disable encrypted connections to the MQTT server.
    /// When enabled, it requires a ``MQTTConnectionConfiguration/TLS/Configuration``
    /// and optionally a server name for SNI (Server Name Indication).
    public struct TLS: Sendable {
        /// Enum for different TLS Configuration types.
        ///
        /// The TLS Configuration type to use is defined by the `EventLoopGroup` the client is using.
        /// If you don't provide an `EventLoopGroup` then the `EventLoopGroup` created will be defined by this variable.
        /// It is recommended on iOS that you use NIO Transport Services.
        public enum Configuration: Sendable {
            /// NIOSSL TLS configuration.
            #if os(macOS) || os(Linux)
            case niossl(TLSConfiguration)
            #endif
            #if canImport(Network)
            /// NIO Transport Services TLS configuration.
            case ts(TSTLSConfiguration)
            #endif
        }
        enum Base {
            case disable
            case enable(Configuration, tlsServerName: String?)
        }
        let base: Base

        /// Disables TLS for the connection.
        ///
        /// Use this option when connecting to an MQTT server that doesn't require encryption.
        public static var disable: Self { .init(base: .disable) }

        /// Enables TLS for the connection.
        ///
        /// - Parameters:
        ///   - configuration: The TLS configuration used to establish the secure connection
        ///   - tlsServerName: Optional server name for SNI (Server Name Indication)
        /// - Returns: A configured TLS instance
        public static func enable(_ configuration: Configuration, tlsServerName: String?) -> Self {
            .init(base: .enable(configuration, tlsServerName: tlsServerName))
        }
    }

    /// Configuration for WebSocket connection.
    public struct WebSocketConfiguration: Sendable {
        /// Creates a WebSocket configuration.
        ///
        /// - Parameters:
        ///   - urlPath: WebSocket URL, defaults to "/mqtt".
        ///   - maxFrameSize: Max frame size WebSocket client will allow.
        ///   - initialRequestHeaders: Additional headers to add to initial HTTP request.
        public init(
            urlPath: String = "/mqtt",
            maxFrameSize: Int = 1 << 14,
            initialRequestHeaders: HTTPHeaders = [:]
        ) {
            self.urlPath = urlPath
            self.maxFrameSize = maxFrameSize
            self.initialRequestHeaders = initialRequestHeaders
        }

        /// WebSocket URL, defaults to "/mqtt".
        public var urlPath: String
        /// Max frame size WebSocket client will allow.
        public var maxFrameSize: Int
        /// Additional headers to add to initial HTTP request.
        public var initialRequestHeaders: HTTPHeaders
    }

    /// Connection configuration for the version of MQTT server to connect to.
    public var versionConfiguration: VersionConfiguration
    /// Disable the automatic sending of `PINGREQ` messages.
    public var disablePing: Bool
    /// MQTT keep alive period.
    public var keepAliveInterval: TimeAmount
    /// Override interval between each `PINGREQ` message.
    public var pingInterval: TimeAmount?
    /// Timeout for connecting to server.
    public var connectTimeout: TimeAmount
    /// Timeout for server response.
    public var timeout: TimeAmount?
    /// MQTT user name.
    public var userName: String?
    /// MQTT password.
    public var password: String?
    /// TLS configuration for the connection.
    ///
    /// Use `.disable` for unencrypted connections or `.enable(...)` for secure connections.
    public var tls: TLS
    /// WebSocket configuration.
    public var webSocketConfiguration: WebSocketConfiguration?

    /// Creates a new MQTT connection configuration.
    ///
    /// - Parameters:
    ///   - versionConfiguration: Connection configuration for the version of MQTT server to connect to.
    ///   - disablePing: Disable the automatic sending of `PINGREQ` messages.
    ///   - keepAliveInterval: MQTT keep alive period.
    ///   - pingInterval: Override calculated interval between each `PINGREQ` message.
    ///   - connectTimeout: Timeout for connecting to server.
    ///   - timeout: Timeout for server ACK responses.
    ///   - userName: MQTT user name.
    ///   - password: MQTT password.
    ///   - tls: TLS configuration for secure connections. Defaults to `.disable` for unencrypted connections.
    ///   - webSocketConfiguration: Configuration to set if using a WebSocket connection.
    public init(
        versionConfiguration: VersionConfiguration = .v3_1_1(),
        disablePing: Bool = false,
        keepAliveInterval: TimeAmount = .seconds(90),
        pingInterval: TimeAmount? = nil,
        connectTimeout: TimeAmount = .seconds(10),
        timeout: TimeAmount? = nil,
        userName: String? = nil,
        password: String? = nil,
        tls: TLS = .disable,
        webSocketConfiguration: WebSocketConfiguration? = nil
    ) {
        self.versionConfiguration = versionConfiguration
        self.disablePing = disablePing
        self.keepAliveInterval = keepAliveInterval
        self.pingInterval = pingInterval
        self.connectTimeout = connectTimeout
        self.timeout = timeout
        self.userName = userName
        self.password = password
        self.tls = tls
        self.webSocketConfiguration = webSocketConfiguration
    }

    /// Whether is using WebSockets for connection.
    public var useWebSockets: Bool {
        self.webSocketConfiguration != nil
    }

    /// URL Path for WebSocket. Defaults to "/mqtt".
    public var webSocketURLPath: String? {
        self.webSocketConfiguration?.urlPath
    }

    /// Maximum frame size for a WebSocket connection.
    public var webSocketMaxFrameSize: Int {
        self.webSocketConfiguration?.maxFrameSize ?? 1 << 14
    }

    /// Version of MQTT server client is connecting to.
    public var version: Version {
        self.versionConfiguration.version
    }
}
