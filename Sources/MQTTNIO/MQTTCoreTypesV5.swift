import NIO

/// MQTT V5 Connack
public struct MQTTConnackV5 {
    /// is using session state from previous session
    public let sessionPresent: Bool
    /// connect reason code
    public let reason: MQTTReasonCode
    /// properties
    public let properties: MQTTProperties
}

/// MQTT V5 ACK information. Returned with PUBACK, PUBREL
public struct MQTTAckV5 {
    /// MQTT v5 disconnection reason
    public var reason: MQTTReasonCode
    /// MQTT v5 properties
    public var properties: MQTTProperties

    init(reason: MQTTReasonCode = .success, properties: MQTTProperties = .init()) {
        self.reason = reason
        self.properties = properties
    }
}

/// MQTT V5 Sub ACK
///
/// Contains data returned in subscribe/unsubscribe ack packets
public struct MQTTSubAckInfoV5 {
    /// MQTT v5 disconnection reason
    public var reasons: [MQTTReasonCode]
    /// MQTT v5 properties
    public var properties: MQTTProperties

    init(reasons: [MQTTReasonCode], properties: MQTTProperties = .init()) {
        self.reasons = reasons
        self.properties = properties
    }
}

