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
