import CCoreMQTT
import NIO

struct MQTTConnectInfo {
    /// Whether to establish a new, clean session or resume a previous session.
    let cleanSession: Bool

    /// MQTT keep alive period.
    let keepAliveSeconds: UInt16

    /// MQTT client identifier. Must be unique per client.
    let clientIdentifier: String

    /// MQTT user name. Set to """ if not used.
    let userName: String

    /// MQTT password. Set to "" if not used.
    let password: String

    func withCoreType<T>(_ body: (MQTTConnectInfo_t) throws -> T) rethrows -> T {
        return try clientIdentifier.withCString { clientIdentifierChars in
            try userName.withCString { userNameChars in
                try password.withCString { passwordChars in
                    let coreType = MQTTConnectInfo_t(
                        cleanSession: self.cleanSession,
                        keepAliveSeconds: self.keepAliveSeconds,
                        pClientIdentifier: clientIdentifierChars,
                        clientIdentifierLength: UInt16(clientIdentifier.utf8.count),
                        pUserName: self.userName.count > 0 ? userNameChars : nil,
                        userNameLength: UInt16(self.userName.utf8.count),
                        pPassword: self.password.count > 0 ? passwordChars : nil,
                        passwordLength: UInt16(self.password.utf8.count)
                    )
                    return try body(coreType)
                }
            }
        }
    }
}

struct MQTTPublishInfo
{
    /// Quality of Service for message.
    let qos: MQTTQoS_t

    /// Whether this is a retained message.
    let retain: Bool

    /// Whether this is a duplicate publish message.
    let dup: Bool

    /// Topic name on which the message is published.
    let topicName: String

    /// Message payload.
    let payload: ByteBuffer
}

struct MQTTSubscribeInfo
{
    /// Quality of Service for subscription.
    let qos: MQTTQoS_t

    /// Topic filter to subscribe to.
    let topicFilter: String

    func withCoreType<T>(_ body: (MQTTSubscribeInfo_t) throws -> T) rethrows -> T {
        return try topicFilter.withCString { topicFilterChars in
            let coreType = MQTTSubscribeInfo_t(
                qos: self.qos,
                pTopicFilter: topicFilterChars,
                topicFilterLength: UInt16(topicFilter.utf8.count)
            )
            return try body(coreType)
        }
    }
}

func serializeConnect(connectInfo: MQTTConnectInfo, publishInfo: MQTTPublishInfo, to byteBuffer: inout ByteBuffer) throws {
    
}
