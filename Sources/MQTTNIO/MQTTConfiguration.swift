//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2021 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
#if canImport(NIOSSL)
import NIOSSL
#endif

extension MQTTClient {
    /// Version of MQTT server to connect to
    public enum Version {
        case v3_1_1
        case v5_0
    }

    /// Enum for different TLS Configuration types. The TLS Configuration type to use if defined by the EventLoopGroup the
    /// client is using. If you don't provide an EventLoopGroup then the EventLoopGroup created will be defined by this variable
    /// It is recommended on iOS you use NIO Transport Services.
    public enum TLSConfigurationType {
        /// NIOSSL TLS configuration
        #if canImport(NIOSSL)
        case niossl(TLSConfiguration)
        #endif
        #if canImport(Network)
        /// NIO Transport Serviecs TLS configuration
        case ts(TSTLSConfiguration)
        #endif
    }

    /// Configuration for MQTTClient
    public struct Configuration {
        /// Initialize MQTTClient configuration struct
        /// - Parameters:
        ///   - version: Version of MQTT server client is connecting to
        ///   - disablePing: Disable the automatic sending of pingreq messages
        ///   - keepAliveInterval: MQTT keep alive period.
        ///   - pingInterval: Override calculated interval between each pingreq message
        ///   - connectTimeout: Timeout for connecting to server
        ///   - timeout: Timeout for server ACK responses
        ///   - userName: MQTT user name
        ///   - password: MQTT password
        ///   - useSSL: Use encrypted connection to server
        ///   - useWebSockets: Use a websocket connection to server
        ///   - tlsConfiguration: TLS configuration, for SSL connection
        ///   - sniServerName: Server name used by TLS. This will default to host name if not set
        ///   - webSocketURLPath: URL Path for web socket. Defaults to "/mqtt"
        ///   - webSocketMaxFrameSize: Maximum frame size for a web socket connection
        public init(
            version: Version = .v3_1_1,
            disablePing: Bool = false,
            keepAliveInterval: TimeAmount = .seconds(90),
            pingInterval: TimeAmount? = nil,
            connectTimeout: TimeAmount = .seconds(10),
            timeout: TimeAmount? = nil,
            userName: String? = nil,
            password: String? = nil,
            useSSL: Bool = false,
            useWebSockets: Bool = false,
            tlsConfiguration: TLSConfigurationType? = nil,
            sniServerName: String? = nil,
            webSocketURLPath: String? = nil,
            webSocketMaxFrameSize: Int = 1 << 14
        ) {
            self.version = version
            self.disablePing = disablePing
            self.keepAliveInterval = keepAliveInterval
            self.pingInterval = pingInterval
            self.connectTimeout = connectTimeout
            self.timeout = timeout
            self.userName = userName
            self.password = password
            self.useSSL = useSSL
            self.useWebSockets = useWebSockets
            self.tlsConfiguration = tlsConfiguration
            self.sniServerName = sniServerName
            self.webSocketURLPath = webSocketURLPath
            self.webSocketMaxFrameSize = webSocketMaxFrameSize
        }

        /// Initialize MQTTClient configuration struct
        /// - Parameters:
        ///   - version: Version of MQTT server client is connecting to
        ///   - disablePing: Disable the automatic sending of pingreq messages
        ///   - keepAliveInterval: MQTT keep alive period.
        ///   - pingInterval: Override calculated interval between each pingreq message
        ///   - connectTimeout: Timeout for connecting to server
        ///   - timeout: Timeout for server ACK responses
        ///   - maxRetryAttempts: Max number of times to send a message. This is deprecated
        ///   - userName: MQTT user name
        ///   - password: MQTT password
        ///   - useSSL: Use encrypted connection to server
        ///   - useWebSockets: Use a websocket connection to server
        ///   - tlsConfiguration: TLS configuration, for SSL connection
        ///   - sniServerName: Server name used by TLS. This will default to host name if not set
        ///   - webSocketURLPath: URL Path for web socket. Defaults to "/mqtt"
        ///   - webSocketMaxFrameSize: Maximum frame size for a web socket connection
        ///
        @available(*, deprecated, message: "maxRetryAttempts is no longer used")
        public init(
            version: Version = .v3_1_1,
            disablePing: Bool = false,
            keepAliveInterval: TimeAmount = .seconds(90),
            pingInterval: TimeAmount? = nil,
            connectTimeout: TimeAmount = .seconds(10),
            timeout: TimeAmount? = nil,
            maxRetryAttempts: Int,
            userName: String? = nil,
            password: String? = nil,
            useSSL: Bool = false,
            useWebSockets: Bool = false,
            tlsConfiguration: TLSConfigurationType? = nil,
            sniServerName: String? = nil,
            webSocketURLPath: String? = nil,
            webSocketMaxFrameSize: Int = 1 << 14
        ) {
            self.version = version
            self.disablePing = disablePing
            self.keepAliveInterval = keepAliveInterval
            self.pingInterval = pingInterval
            self.connectTimeout = connectTimeout
            self.timeout = timeout
            self.userName = userName
            self.password = password
            self.useSSL = useSSL
            self.useWebSockets = useWebSockets
            self.tlsConfiguration = tlsConfiguration
            self.sniServerName = sniServerName
            self.webSocketURLPath = webSocketURLPath
            self.webSocketMaxFrameSize = webSocketMaxFrameSize
        }

        /// Version of MQTT server client is connecting to
        public let version: Version
        /// disable the automatic sending of pingreq messages
        public let disablePing: Bool
        /// MQTT keep alive period.
        public let keepAliveInterval: TimeAmount
        /// override interval between each pingreq message
        public let pingInterval: TimeAmount?
        /// timeout for connecting to server
        public let connectTimeout: TimeAmount
        /// timeout for server response
        public let timeout: TimeAmount?
        /// MQTT user name.
        public let userName: String?
        /// MQTT password.
        public let password: String?
        /// use encrypted connection to server
        public let useSSL: Bool
        /// use a websocket connection to server
        public let useWebSockets: Bool
        /// TLS configuration
        public let tlsConfiguration: TLSConfigurationType?
        /// server name used by TLS
        public let sniServerName: String?
        /// URL Path for web socket. Defaults to "/mqtt"
        public let webSocketURLPath: String?
        /// Maximum frame size for a web socket connection
        public let webSocketMaxFrameSize: Int
    }
}
