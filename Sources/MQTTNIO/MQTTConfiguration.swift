import NIO
#if canImport(NIOSSL)
import NIOSSL
#endif

extension MQTTClient {
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
        public init(
            version: Version = .v3_1_1,
            disablePing: Bool = false,
            keepAliveInterval: TimeAmount = .seconds(90),
            pingInterval: TimeAmount? = nil,
            timeout: TimeAmount? = .seconds(10),
            maxRetryAttempts: Int = 4,
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
            self.timeout = timeout
            self.maxRetryAttempts = maxRetryAttempts
            self.userName = userName
            self.password = password
            self.useSSL = useSSL
            self.useWebSockets = useWebSockets
            self.tlsConfiguration = tlsConfiguration
            self.sniServerName = sniServerName
            self.webSocketURLPath = webSocketURLPath
            self.webSocketMaxFrameSize = webSocketMaxFrameSize
        }

        /// disable the sending of pingreq messages
        public let version: Version
        /// disable the sending of pingreq messages
        public let disablePing: Bool
        /// MQTT keep alive period.
        public let keepAliveInterval: TimeAmount
        /// override interval between each pingreq message
        public let pingInterval: TimeAmount?
        /// timeout for server response
        public let timeout: TimeAmount?
        /// max number of times to send a message
        public let maxRetryAttempts: Int
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
