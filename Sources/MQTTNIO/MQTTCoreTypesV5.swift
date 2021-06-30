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
    /// MQTT v5 reason code
    public let reason: MQTTReasonCode
    /// MQTT v5 properties
    public let properties: MQTTProperties

    init(reason: MQTTReasonCode = .success, properties: MQTTProperties = .init()) {
        self.reason = reason
        self.properties = properties
    }
}

/// MQTT SUBSCRIBE packet parameters.
public struct MQTTSubscribeInfoV5 {
    /// Retain handling options
    public enum RetainHandling: UInt8 {
        /// always send retain message
        case sendAlways = 0
        /// send retain if new
        case sendIfNew = 1
        /// do not send retain message
        case doNotSend = 2
    }

    /// Topic filter to subscribe to.
    public let topicFilter: String

    /// Quality of Service for subscription.
    public let qos: MQTTQoS

    /// Don't forward message published by this client
    public let noLocal: Bool

    /// Keep retain flag message was published with
    public let retainAsPublished: Bool

    /// Retain handing
    public let retainHandling: RetainHandling

    public init(
        topicFilter: String,
        qos: MQTTQoS,
        noLocal: Bool = false,
        retainAsPublished: Bool = true,
        retainHandling: RetainHandling = .sendIfNew
    ) {
        self.qos = qos
        self.topicFilter = topicFilter
        self.noLocal = noLocal
        self.retainAsPublished = retainAsPublished
        self.retainHandling = retainHandling
    }
}

/// MQTT V5 Sub ACK
///
/// Contains data returned in subscribe/unsubscribe ack packets
public struct MQTTSubackV5 {
    /// MQTT v5 subscription reason code
    public let reasons: [MQTTReasonCode]
    /// MQTT v5 properties
    public let properties: MQTTProperties

    init(reasons: [MQTTReasonCode], properties: MQTTProperties = .init()) {
        self.reasons = reasons
        self.properties = properties
    }
}

/// MQTT V5 Sub ACK
///
/// Contains data returned in subscribe/unsubscribe ack packets
public struct MQTTAuthV5 {
    /// MQTT v5 authentication reason code
    public let reason: MQTTReasonCode
    /// MQTT v5 properties
    public let properties: MQTTProperties

    init(reason: MQTTReasonCode, properties: MQTTProperties) {
        self.reason = reason
        self.properties = properties
    }
}
