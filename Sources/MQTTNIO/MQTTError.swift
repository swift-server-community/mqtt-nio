//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

/// MQTTNIO errors
@nonexhaustive
public enum MQTTError: Error, Sendable {
    /// Value returned in connection error
    public enum ConnectionReturnValue: UInt8, Sendable {
        /// connection was accepted
        case accepted = 0
        /// The Server does not support the version of the MQTT protocol requested by the Client.
        case unacceptableProtocolVersion = 1
        /// The Client Identifier is a valid string but is not allowed by the Server.
        case identifierRejected = 2
        /// The MQTT Server is not available.
        case serverUnavailable = 3
        /// The Server does not accept the User Name or Password specified by the Client
        case badUserNameOrPassword = 4
        /// The client is not authorized to connect
        case notAuthorized = 5
        /// Return code was unrecognised
        case unrecognizedReturnValue = 0xFF
    }

    /// We received an unexpected packet while connecting
    case failedToConnect
    /// We received an unsuccessful connection return value
    case connectionError(ConnectionReturnValue)
    /// We received an unsuccessful return value from either a connect or publish
    case reasonError(MQTTReasonCode)
    /// client is closed
    case connectionClosed
    /// the server disconnected with a DISCONNECT packet
    case serverDisconnection(MQTTAckV5)
    /// the server closed the connection. If this happens during a publish and you
    /// are using sessions the publish will finish sending on re-connection.
    case serverClosedConnection
    /// received unexpected packet from server
    case unexpectedPacket
    /// Decode of MQTT packet failed
    case decodeError
    /// Upgrade to websocket failed
    case websocketUpgradeFailed
    /// client timed out while waiting for response from server
    case timeout
    /// You have provided the wrong TLS configuration for the EventLoopGroup you provided
    case wrongTLSConfig
    /// Packet received contained invalid entries
    case badResponse
    /// Failed to recognise the packet control type
    case unrecognisedPacketType
    /// Auth packets sent without authWorkflow being supplied
    case authWorkflowRequired
    /// MQTT version mismatch
    case versionMismatch(expected: MQTTConnectionConfiguration.Version, actual: MQTTConnectionConfiguration.Version)
    /// Sending a packet was cancelled
    case cancelled
    /// The provided topic filter is invalid
    case invalidTopicFilter(String)
    /// The packet size is greater than Maximum Packet Size for this Server.
    case packetTooLarge
    /// Another ``MQTTConnection`` is already connected with this ``MQTTSession``.
    case alreadyConnectedWithSession
    /// The subscription was closed because the MQTT Server does not have a session matching the
    /// provided Client Identifier.
    case noSessionPresent
}

/// Errors generated from bad packets sent by the client
@nonexhaustive
public enum MQTTPacketError: Error {
    /// Packet sent contained invalid entries
    case badParameter
    /// QoS is not accepted by this connection as it is greater than the accepted value
    case qosInvalid
    /// publish messages on this connection do not support the retain flag
    case retainUnavailable
    /// subscribe/unsubscribe packet requires at least one topic
    case atLeastOneTopicRequired
    /// topic alias is greater than server maximum topic alias or the alias is zero
    case topicAliasOutOfRange
    /// invalid topic name
    case invalidTopicName
    /// client to server publish packets cannot include a subscription identifier
    case publishIncludesSubscription
}
