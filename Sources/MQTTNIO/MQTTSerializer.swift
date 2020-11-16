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
        let mqttPublishAckPacketSize = 4

        try byteBuffer.writeWithUnsafeMutableType(minimumWritableBytes: mqttPublishAckPacketSize) { fixedBuffer in
            var fixedBuffer = fixedBuffer
            let rt = MQTT_SerializeAck(&fixedBuffer, packetType.rawValue, packetId)
            guard rt == MQTTSuccess else { throw MQTTError(status: rt) }
            return mqttPublishAckPacketSize
        }
    }

    static func writeDisconnect(to byteBuffer: inout ByteBuffer) throws {
        var packetSize: Int = 0
        let rt = MQTT_GetDisconnectPacketSize(&packetSize)
        guard rt == MQTTSuccess else { throw MQTTError(status: rt) }

        try byteBuffer.writeWithUnsafeMutableType(minimumWritableBytes: packetSize) { fixedBuffer in
            var fixedBuffer = fixedBuffer
            let rt = MQTT_SerializeDisconnect(&fixedBuffer)
            guard rt == MQTTSuccess else { throw MQTTError(status: rt) }
            return packetSize
        }
    }

    static func writePingreq(to byteBuffer: inout ByteBuffer) throws {
        var packetSize: Int = 0
        let rt = MQTT_GetPingreqPacketSize(&packetSize)
        guard rt == MQTTSuccess else { throw MQTTError(status: rt) }

        try byteBuffer.writeWithUnsafeMutableType(minimumWritableBytes: packetSize) { fixedBuffer in
            var fixedBuffer = fixedBuffer
            let rt = MQTT_SerializePingreq(&fixedBuffer)
            guard rt == MQTTSuccess else { throw MQTTError(status: rt) }
            return packetSize
        }
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
            let offset = publishInfoCoreType.pPayload - remainingDataPtr
            guard let payload = packet.remainingData.getSlice(at: offset, length: publishInfoCoreType.payloadLength) else { throw MQTTError(status: .MQTTNoMemory) }
            
            return MQTTPublishInfo(
                qos: MQTTQoS(rawValue: publishInfoCoreType.qos.rawValue)!,
                retain: publishInfoCoreType.retain,
                dup: publishInfoCoreType.dup,
                topicName: topicName,
                payload: payload
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
        guard let type = MQTTPacketType(rawValue: byte & 0xf0) else { print("Bad parameter \(byte)"); throw MQTTError(status: MQTTBadParameter)}
        let length = try readLength(from: &byteBuffer)
        guard let bytes = byteBuffer.readSlice(length: length) else { throw Error.incompletePacket }
        return MQTTPacketInfo(type: type, remainingData: bytes)
    }
}

extension MQTTSerializer {
    static func readLength(from byteBuffer: inout ByteBuffer) throws -> Int {
        var length = 0
        repeat {
            guard let byte: UInt8 = byteBuffer.readInteger() else { throw Error.incompletePacket }
            length += Int(byte) & 0x7f
            if byte & 0x80 == 0 {
                break
            }
            length <<= 7
        } while(true)
        return length
    }
}
