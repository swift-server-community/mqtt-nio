import NIO

public enum MQTTQoS: UInt8 {
    /// fire and forget
    case atMostOnce = 0
    /// wait for PUBACK, if you don't receive it after a period of time retry sending
    case atLeastOnce = 1
    /// wait for PUBREC, send PUBREL and then wait for PUBCOMP
    case exactlyOnce = 2
}

public enum MQTTPacketType: UInt8 {
    case CONNECT = 0x10
    case CONNACK = 0x20
    case PUBLISH = 0x30
    case PUBACK = 0x40
    case PUBREC = 0x50
    case PUBREL = 0x62
    case PUBCOMP = 0x70
    case SUBSCRIBE = 0x82
    case SUBACK = 0x90
    case UNSUBSCRIBE = 0xA2
    case UNSUBACK = 0xB0
    case PINGREQ = 0xC0
    case PINGRESP = 0xD0
    case DISCONNECT = 0xE0
}

/// MQTT CONNECT packet parameters
struct MQTTConnectInfo {
    /// Whether to establish a new, clean session or resume a previous session.
    let cleanSession: Bool

    /// MQTT keep alive period.
    let keepAliveSeconds: UInt16

    /// MQTT client identifier. Must be unique per client.
    let clientIdentifier: String

    /// MQTT user name.
    let userName: String?

    /// MQTT password.
    let password: String?
}

/// MQTT PUBLISH packet parameters.
public struct MQTTPublishInfo
{
    /// Quality of Service for message.
    public let qos: MQTTQoS

    /// Whether this is a retained message.
    public let retain: Bool

    /// Whether this is a duplicate publish message.
    public let dup: Bool

    /// Topic name on which the message is published.
    public let topicName: String

    /// Message payload.
    public let payload: ByteBuffer

    public init(qos: MQTTQoS, retain: Bool, dup: Bool = false, topicName: String, payload: ByteBuffer) {
        self.qos = qos
        self.retain = retain
        self.dup = dup
        self.topicName = topicName
        self.payload = payload
    }

    static let emptyByteBuffer = ByteBufferAllocator().buffer(capacity: 0);
}

/// MQTT SUBSCRIBE packet parameters.
public struct MQTTSubscribeInfo
{
    /// Topic filter to subscribe to.
    public let topicFilter: String

    /// Quality of Service for subscription.
    public let qos: MQTTQoS

    public init(topicFilter: String, qos: MQTTQoS) {
        self.qos = qos
        self.topicFilter = topicFilter
    }
}

/// MQTT incoming packet parameters.
struct MQTTPacketInfo
{
    /// Type of incoming MQTT packet.
    let type: MQTTPacketType

    /// packet flags
    let flags: UInt8

    /// Remaining serialized data in the MQTT packet.
    let remainingData: ByteBuffer
}
