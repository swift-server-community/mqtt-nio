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
    /// Packet sent contained invalid entries
    case badParameter
    /// Packet received contained invalid entries
    case badResponse
    /// Auth packets sent without authWorkflow being supplied
    case authWorkflowRequired
    /// QoS is not accepted by this connection as it is greater than the accepted value
    case qosInvalid
    /// publish messages on this connection do not support the retain flag
    case retainUnavailable
    /// subscribe/unsubscribe packet requires at least one topic
    case atLeastOneTopicRequired
}
