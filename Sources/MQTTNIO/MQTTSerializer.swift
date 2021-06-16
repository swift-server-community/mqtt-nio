import CCoreMQTT
import Foundation
import NIO

enum MQTTSerializer {
    struct MQTTError: Swift.Error {
        let status: MQTTStatus

        init(status: MQTTStatus_t) {
            self.status = MQTTStatus(rawValue: status.rawValue)!
        }
        init(status: MQTTStatus) {
            self.status = status
        }

        static var badParameter: MQTTError { .init(status: .MQTTBadParameter) }
    }

    enum Error: Swift.Error {
        case incompletePacket
    }

    /// write fixed header for packet
    static func writeFixedHeader(packetType: MQTTPacketType, flags: UInt8 = 0, size: Int, to byteBuffer: inout ByteBuffer) {
        byteBuffer.writeInteger(packetType.rawValue | flags)
        writeLength(size, to: &byteBuffer)
    }
    
    /// write variable length
    static func writeLength(_ length: Int, to byteBuffer: inout ByteBuffer) {
        var length = length
        repeat {
            let byte = UInt8(length & 0x7f)
            length >>= 7
            if length != 0 {
                byteBuffer.writeInteger(byte | 0x80)
            } else {
                byteBuffer.writeInteger(byte)
            }
        } while length != 0
    }

    /// write string
    static func writeString(_ string: String, to byteBuffer: inout ByteBuffer) throws {
        let length = string.utf8.count
        guard length < 65536 else { throw MQTTError.badParameter }
        byteBuffer.writeInteger(UInt16(length))
        byteBuffer.writeString(string)
    }

    /// calculate size of connect packet
    /*static func calculateConnectPacketSize(connectInfo: MQTTConnectInfo, publishInfo: MQTTPublishInfo?) -> Int {
        // variable header
        var size = 10
        // payload
        // identifier
        return size
    }*/

    static func writeConnect(connectInfo: MQTTConnectInfo, willInfo: MQTTPublishInfo?, to byteBuffer: inout ByteBuffer) throws {
        var remainingLength: Int = 0
        var packetSize: Int = 0
        try connectInfo.withUnsafeType { connectInfo in
            if let willInfo = willInfo {
                try willInfo.withUnsafeType { publishInfo in
                    var connectInfo = connectInfo
                    var publishInfo = publishInfo
                    let rt = MQTT_GetConnectPacketSize(&connectInfo, &publishInfo, &remainingLength, &packetSize)
                    guard rt == MQTTSuccess else { throw MQTTError(status: rt) }

                    _ = try byteBuffer.writeWithUnsafeMutableType(minimumWritableBytes: packetSize) { fixedBuffer in
                        var connectInfo = connectInfo
                        var publishInfo = publishInfo
                        var fixedBuffer = fixedBuffer
                        let rt = MQTT_SerializeConnect(&connectInfo, &publishInfo, remainingLength, &fixedBuffer)
                        guard rt == MQTTSuccess else { throw MQTTError(status: rt) }
                        return packetSize
                    }
                }
            } else {
                var connectInfo = connectInfo
                let rt = MQTT_GetConnectPacketSize(&connectInfo, nil, &remainingLength, &packetSize)
                guard rt == MQTTSuccess else { throw MQTTError(status: rt) }

                _ = try byteBuffer.writeWithUnsafeMutableType(minimumWritableBytes: packetSize) { fixedBuffer in
                    var connectInfo = connectInfo
                    var fixedBuffer = fixedBuffer
                    let rt = MQTT_SerializeConnect(&connectInfo, nil, remainingLength, &fixedBuffer)
                    guard rt == MQTTSuccess else { throw MQTTError(status: rt) }
                    return packetSize
                }
            }
        }
    }

    /// calculate size of publish packet
    static func calculatePublishPacketSize(publishInfo: MQTTPublishInfo) -> Int {
        // topic name
        var size = publishInfo.topicName.utf8.count
        if publishInfo.qos != .atMostOnce {
            size += 2
        }
        // packet identifier
        size += 2
        // payload
        size += publishInfo.payload.readableBytes
        return size
    }

    /// write publish packet
    static func writePublish(publishInfo: MQTTPublishInfo, packetId: UInt16, to byteBuffer: inout ByteBuffer) throws {
        var flags: UInt8 = publishInfo.retain ? 1 : 0
        flags |= publishInfo.qos.rawValue << 1
        flags |= publishInfo.dup ? (1<<3) : 0

        let length = calculatePublishPacketSize(publishInfo: publishInfo)

        writeFixedHeader(packetType: .PUBLISH, flags: flags, size: length, to: &byteBuffer)
        // write variable header
        try writeString(publishInfo.topicName, to: &byteBuffer)
        if publishInfo.qos != .atMostOnce {
            byteBuffer.writeInteger(packetId)
        }
        // write payload
        var payload = publishInfo.payload
        byteBuffer.writeBuffer(&payload)
    }

    /// calculate size of subscribe packet
    static func calculateSubscribePacketSize(subscribeInfos: [MQTTSubscribeInfo]) -> Int {
        // packet identifier
        let size = 2
        // payload
        return subscribeInfos.reduce(size) {
            $0 + 2 + $1.topicFilter.utf8.count + 1  // topic filter length + topic filter + qos
        }
    }

    /// write subscribe packet
    static func writeSubscribe(subscribeInfos: [MQTTSubscribeInfo], packetId: UInt16, to byteBuffer: inout ByteBuffer) throws {
        let length = calculateSubscribePacketSize(subscribeInfos: subscribeInfos)

        writeFixedHeader(packetType: .SUBSCRIBE, size: length, to: &byteBuffer)
        // write variable header
        byteBuffer.writeInteger(packetId)
        // write payload
        for info in subscribeInfos {
            try writeString(info.topicFilter, to: &byteBuffer)
            byteBuffer.writeInteger(info.qos.rawValue)
        }
    }

    /// calculate size of subscribe packet
    static func calculateUnsubscribePacketSize(subscribeInfos: [MQTTSubscribeInfo]) -> Int {
        // packet identifier
        let size = 2
        // payload
        return subscribeInfos.reduce(size) {
            $0 + 2 + $1.topicFilter.utf8.count  // topic filter length + topic filter
        }
    }

    /// write unsubscribe packet
    static func writeUnsubscribe(subscribeInfos: [MQTTSubscribeInfo], packetId: UInt16, to byteBuffer: inout ByteBuffer) throws {
        let length = calculateUnsubscribePacketSize(subscribeInfos: subscribeInfos)

        writeFixedHeader(packetType: .UNSUBSCRIBE, size: length, to: &byteBuffer)
        // write variable header
        byteBuffer.writeInteger(packetId)
        // write payload
        for info in subscribeInfos {
            try writeString(info.topicFilter, to: &byteBuffer)
        }
    }

    static func writeAck(packetType: MQTTPacketType, packetId: UInt16, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: packetType, size: 2, to: &byteBuffer)
        byteBuffer.writeInteger(packetId)
    }

    static func writeDisconnect(to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .DISCONNECT, size: 0, to: &byteBuffer)
    }

    static func writePingreq(to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .PINGREQ, size: 0, to: &byteBuffer)
    }

    static func readPublish(from packet: MQTTPacketInfo) throws -> (packetId: UInt16, publishInfo: MQTTPublishInfo) {
        var packetId: UInt16 = 0

        let publishInfo: MQTTPublishInfo = try packet.withUnsafeType { packetInfo in
            var packetInfo = packetInfo
            var publishInfoCoreType = MQTTPublishInfo_t()
            let rt = MQTT_DeserializePublish(&packetInfo, &packetId, &publishInfoCoreType)
            guard rt == MQTTSuccess else { throw MQTTError(status: rt) }

            // Topic string
            let topicName = String(
                decoding: UnsafeRawBufferPointer(start: publishInfoCoreType.pTopicName, count: Int(publishInfoCoreType.topicNameLength)),
                as: Unicode.UTF8.self
            )
            // Payload
            guard let remainingDataPtr = UnsafeRawPointer(packetInfo.pRemainingData) else { throw MQTTError(status: .MQTTNoMemory) }
            let payloadByteBuffer: ByteBuffer
            // publish packet may not have payload
            if let pPayload = publishInfoCoreType.pPayload {
                let offset = pPayload - remainingDataPtr
                guard let payload = packet.remainingData.getSlice(at: offset, length: publishInfoCoreType.payloadLength) else { throw MQTTError(status: .MQTTNoMemory) }
                payloadByteBuffer = payload
            } else {
                payloadByteBuffer = MQTTPublishInfo.emptyByteBuffer
            }
            return MQTTPublishInfo(
                qos: MQTTQoS(rawValue: UInt8(publishInfoCoreType.qos.rawValue))!,
                retain: publishInfoCoreType.retain,
                dup: publishInfoCoreType.dup,
                topicName: topicName,
                payload: payloadByteBuffer
            )
        }
        return (packetId: packetId, publishInfo: publishInfo)
    }

    static func readAck(from packet: MQTTPacketInfo) throws -> (packetId: UInt16, sessionPresent: Bool) {
        var packetId: UInt16 = 0
        var sessionPresent: Bool = false
        let rt = packet.withUnsafeType { packetInfo -> MQTTStatus_t in
            var packetInfo = packetInfo
            return MQTT_DeserializeAck(&packetInfo, &packetId, &sessionPresent)
        }
        guard rt == MQTTSuccess else { throw MQTTError(status: rt) }
        return (packetId: packetId, sessionPresent: sessionPresent)
    }

    static func readIncomingPacket(from byteBuffer: inout ByteBuffer) throws -> MQTTPacketInfo {
        guard let byte: UInt8 = byteBuffer.readInteger() else { throw Error.incompletePacket }
        guard let type = MQTTPacketType(rawValue: byte) ?? MQTTPacketType(rawValue: byte & 0xf0) else {
            throw MQTTError(status: MQTTBadParameter)
        }
        let length = try readLength(from: &byteBuffer)
        guard let bytes = byteBuffer.readSlice(length: length) else { throw Error.incompletePacket }
        return MQTTPacketInfo(type: type, flags: byte & 0xf, remainingData: bytes)
    }
}

extension MQTTSerializer {
    static func readLength(from byteBuffer: inout ByteBuffer) throws -> Int {
        var length = 0
        var shift = 0
        repeat {
            guard let byte: UInt8 = byteBuffer.readInteger() else { throw Error.incompletePacket }
            length += (Int(byte) & 0x7f) << shift
            if byte & 0x80 == 0 {
                break
            }
            shift += 7
        } while(true)
        return length
    }
}
