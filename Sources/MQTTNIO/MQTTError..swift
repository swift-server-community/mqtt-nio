/// MQTTClient errors
enum MQTTError: Error {
    /// You called connect on a client that is already connected to the broker
    case alreadyConnected
    /// We received an unexpected message while connecting
    case failedToConnect
    /// client in not connected
    case noConnection
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
}
