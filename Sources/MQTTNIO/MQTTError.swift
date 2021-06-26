/// MQTTClient errors
enum MQTTError: Error {
    enum ConnectionReturnValue: UInt8 {
        case accepted = 0
        case unacceptableProtocolVersion = 1
        case identifierRejected = 2
        case serverUnavailable = 3
        case badUserNameOrPassword = 4
        case notAuthorized = 5
        case unrecognizedReturnValue = 0xFF
    }

    /// You called connect on a client that is already connected to the broker
    case alreadyConnected
    /// We received an unexpected message while connecting
    case failedToConnect
    /// We received an unsuccessful connection return value
    case connectionError(ConnectionReturnValue)
    /// We received an unsuccessful return value from either a connect or publish
    case reasonError(MQTTReasonCode)
    /// client in not connected
    case noConnection
    /// the server disconnected
    case serverDisconnection(MQTTAckV5)
    /// the server closed the connection
    case serverClosedConnection
    /// received unexpected message from broker
    case unexpectedMessage
    /// Decode of MQTT message failed
    case decodeError
    /// Upgrade to websocker failed
    case websocketUpgradeFailed
    /// client timed out while waiting for response from server
    case timeout
    /// Internal error, used to get the client to retry sending
    case retrySend
    /// You have provided the wrong TLS configuration for the EventLoopGroup you provided
    case wrongTLSConfig
    /// Packet received contained invalid entries
    case badResponse
    /// Failed to recognise the packet control type
    case unrecognisedPacketType
    /// Auth packets sent without authWorkflow being supplied
    case authWorkflowRequired
}

/// Errors generated by bad packets sent by the client
struct MQTTPacketError: Error, Equatable {
    /// Packet sent contained invalid entries
    public static var badParameter: MQTTPacketError { .init(error: .badParameter) }
    /// QoS is not accepted by this connection as it is greater than the accepted value
    public static var qosInvalid: MQTTPacketError { .init(error: .qosInvalid) }
    /// publish messages on this connection do not support the retain flag
    public static var retainUnavailable: MQTTPacketError { .init(error: .retainUnavailable) }
    /// subscribe/unsubscribe packet requires at least one topic
    public static var atLeastOneTopicRequired: MQTTPacketError { .init(error: .atLeastOneTopicRequired) }
    /// topic alias is greater than server maximum topic alias
    public static var topicAliasOutOfRange: MQTTPacketError { .init(error: .topicAliasOutOfRange) }
    /// invalid topic name
    public static var invalidTopicName: MQTTPacketError { .init(error: .invalidTopicName) }

    private enum _Error {
        case badParameter
        case qosInvalid
        case retainUnavailable
        case atLeastOneTopicRequired
        case topicAliasOutOfRange
        case invalidTopicName
    }

    private let error: _Error
}
