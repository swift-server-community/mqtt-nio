import CCoreMQTT
import NIO

public enum MQTTQoS: UInt8 {
    /// fire and forget
    case atMostOnce = 0
    /// wait for PUBACK, if you don't receive it after a period of time retry sending
    case atLeastOnce = 1
    /// wait for PUBREC, send PUBREL and then wait for PUBCOMP
    case exactlyOnce = 2

    var coreType: MQTTQoS_t { .init(rawValue: UInt32(self.rawValue)) }
}

public enum MQTTStatus: UInt32 {
    /// Function completed successfully
    case MQTTSuccess = 0
    /// At least one parameter was invalid
    case MQTTBadParameter
    /// A provided buffer was too small.
    case MQTTNoMemory
    /// The transport send function failed
    case MQTTSendFailed
    /// The transport receive function failed
    case MQTTRecvFailed
    /// An invalid packet was received from the server.
    case MQTTBadResponse
    /// The server refused a CONNECT or SUBSCRIBE
    case MQTTServerRefused
    /// No data available from the transport interface
    case MQTTNoDataAvailable
    /// An illegal state in the state record
    case MQTTIllegalState
    /// A collision with an existing state record entry
    case MQTTStateCollision
    /// Timeout while waiting for PINGRESP
    case MQTTKeepAliveTimeout
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

/// Buffer passed to MQTT library
extension ByteBuffer {
    func withUnsafeType<T>(_ body: (MQTTFixedBuffer_t) throws -> T) rethrows -> T {
        var buffer = self
        return try buffer.withUnsafeMutableReadableBytes { bytes in
            let coreType = MQTTFixedBuffer_t(
                pBuffer: CCoreMQTT_voidPtr_to_UInt8Ptr(bytes.baseAddress),
                size: self.readableBytes
            )
            return try body(coreType)
        }
    }

    @discardableResult mutating func writeWithUnsafeMutableType(minimumWritableBytes: Int, _ body: (MQTTFixedBuffer_t) throws -> Int) rethrows -> Int {
        return try writeWithUnsafeMutableBytes(minimumWritableBytes: minimumWritableBytes) { bytes in
            let coreType = MQTTFixedBuffer_t(
                pBuffer: CCoreMQTT_voidPtr_to_UInt8Ptr(bytes.baseAddress),
                size: minimumWritableBytes
            )
            return try body(coreType)
        }
    }
}

/// MQTT CONNECT packet parameters
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

    func withUnsafeType<T>(_ body: (MQTTConnectInfo_t) throws -> T) rethrows -> T {
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

    func withUnsafeType<T>(_ body: (MQTTPublishInfo_t) throws -> T) rethrows -> T {
        return try topicName.withCString { topicNameChars in
            try payload.withUnsafeReadableBytes { payloadBytes in
                let coreType = MQTTPublishInfo_t(
                    qos: self.qos.coreType,
                    retain: self.retain,
                    dup: self.dup,
                    pTopicName: topicNameChars,
                    topicNameLength: UInt16(topicName.utf8.count),
                    pPayload: payloadBytes.baseAddress,
                    payloadLength: payload.readableBytes
                )
                return try body(coreType)
            }
        }
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

    func withUnsafeType<T>(_ body: (MQTTSubscribeInfo_t) throws -> T) rethrows -> T {
        return try topicFilter.withCString { topicFilterChars in
            let coreType = MQTTSubscribeInfo_t(
                qos: qos.coreType,
                pTopicFilter: topicFilterChars,
                topicFilterLength: UInt16(topicFilter.utf8.count)
            )
            return try body(coreType)
        }
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

    func withUnsafeType<T>(_ body: (MQTTPacketInfo_t) throws -> T) rethrows -> T {
        var remainingData = self.remainingData
        return try remainingData.withUnsafeMutableReadableBytes { remainingBytes in
            let coreType = MQTTPacketInfo_t(
                type: type.rawValue | flags,
                pRemainingData: CCoreMQTT_voidPtr_to_UInt8Ptr(remainingBytes.baseAddress),
                remainingLength: self.remainingData.readableBytes
            )
            return try body(coreType)
        }
    }
}

/// Compute the prefix sum of `seq`.
func scan<S : Sequence, U>(_ seq: S, _ initial: U, _ combine: (U, S.Element) -> U) -> [U] {
  var result: [U] = []
  result.reserveCapacity(seq.underestimatedCount)
  var runningResult = initial
  for element in seq {
    runningResult = combine(runningResult, element)
    result.append(runningResult)
  }
  return result
}

extension Array where Element == MQTTSubscribeInfo {
    func withUnsafeType<T>(_ body: ([MQTTSubscribeInfo_t]) throws -> T) rethrows -> T {
        let counts = map { $0.topicFilter.utf8.count + 1}
        let offsets = [0] + scan(counts, 0, +)
        let bufferSize = offsets.last!
        var buffer: [UInt8] = []
        buffer.reserveCapacity(bufferSize)
        forEach {
            buffer.append(contentsOf: $0.topicFilter.utf8)
            buffer.append(0)
        }
        return try buffer.withUnsafeBufferPointer { buffer in
            let basePtr = UnsafeRawPointer(buffer.baseAddress!).bindMemory(to: CChar.self, capacity: buffer.count)
            var infos: [MQTTSubscribeInfo_t] = []
            infos.reserveCapacity(count)
            for i in 0..<count {
                let topicPtr: UnsafePointer<CChar>? = basePtr + offsets[i]
                let topicFilterLength = self[i].topicFilter.count
                let qos = self[i].qos.coreType
                infos.append(MQTTSubscribeInfo_t(qos: qos, pTopicFilter: topicPtr, topicFilterLength: UInt16(topicFilterLength)))
            }
            return try body(infos)
        }
    }
}
