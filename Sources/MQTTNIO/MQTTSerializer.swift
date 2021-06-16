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
    }

    enum Error: Swift.Error {
        case incompletePacket
    }

    /// write fixed header for packet
    static func writeFixedHeader(packetType: MQTTPacketType, flags: UInt8 = 0, size: UInt32, to byteBuffer: inout ByteBuffer) {
        byteBuffer.writeInteger(packetType.rawValue | flags)
        writeLength(size, to: &byteBuffer)
    }
    
    /// write variable length
    static func writeLength(_ length: UInt32, to byteBuffer: inout ByteBuffer) {
        var length = length
        repeat {
            let byte = UInt8(length & 0x7f)
            length >>= 8
            if length != 0 {
                byteBuffer.writeInteger(byte | 0x80)
            } else {
                byteBuffer.writeInteger(byte)
            }
        } while length != 0
    }
    
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

    static func writePublish(publishInfo: MQTTPublishInfo, packetId: UInt16, to byteBuffer: inout ByteBuffer) throws {
        var flags: UInt8 = publishInfo.retain ? 1 : 0
        flags |= publishInfo.qos.rawValue << 1
        flags |= publishInfo.dup ? (1<<3) : 0
        //writeFixedHeader(packetType: packetType, flags: flags, size: 2, to: &byteBuffer)

        var remainingLength: Int = 0
        var packetSize: Int = 0
        try publishInfo.withUnsafeType { publishInfo in
            var publishInfo = publishInfo
            let rt = MQTT_GetPublishPacketSize(&publishInfo, &remainingLength, &packetSize)
            guard rt == MQTTSuccess else { throw MQTTError(status: rt) }

            _ = try byteBuffer.writeWithUnsafeMutableType(minimumWritableBytes: packetSize) { fixedBuffer in
                var publishInfo = publishInfo
                var fixedBuffer = fixedBuffer
                let rt = MQTT_SerializePublish(&publishInfo, packetId, remainingLength, &fixedBuffer)
                guard rt == MQTTSuccess else { throw MQTTError(status: rt) }
                return packetSize
            }
        }
    }

    static func writeSubscribe(subscribeInfos: [MQTTSubscribeInfo], packetId: UInt16, to byteBuffer: inout ByteBuffer) throws {
        var remainingLength: Int = 0
        var packetSize: Int = 0
        try subscribeInfos.withUnsafeType { subscribeInfos in
            let rt = MQTT_GetSubscribePacketSize(subscribeInfos, subscribeInfos.count, &remainingLength, &packetSize)
            guard rt == MQTTSuccess else { throw MQTTError(status: rt) }

            try byteBuffer.writeWithUnsafeMutableType(minimumWritableBytes: packetSize) { fixedBuffer in
                var fixedBuffer = fixedBuffer
                let rt = MQTT_SerializeSubscribe(subscribeInfos, subscribeInfos.count, packetId, remainingLength, &fixedBuffer)
                guard rt == MQTTSuccess else { throw MQTTError(status: rt) }
                return packetSize
            }
        }
    }

    static func writeUnsubscribe(subscribeInfos: [MQTTSubscribeInfo], packetId: UInt16, to byteBuffer: inout ByteBuffer) throws {
        var remainingLength: Int = 0
        var packetSize: Int = 0
        try subscribeInfos.withUnsafeType { subscribeInfos in
            let rt = MQTT_GetUnsubscribePacketSize(subscribeInfos, subscribeInfos.count, &remainingLength, &packetSize)
            guard rt == MQTTSuccess else { throw MQTTError(status: rt) }

            try byteBuffer.writeWithUnsafeMutableType(minimumWritableBytes: packetSize) { fixedBuffer in
                var fixedBuffer = fixedBuffer
                let rt = MQTT_SerializeUnsubscribe(subscribeInfos, subscribeInfos.count, packetId, remainingLength, &fixedBuffer)
                guard rt == MQTTSuccess else { throw MQTTError(status: rt) }
                return packetSize
            }
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
