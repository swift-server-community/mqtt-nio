import Foundation
import NIO

enum MQTTSerializer {
    struct MQTTError: Swift.Error {
        enum ErrorEnum {
            case badParameter
            case badResponse
            case incompletePacket
        }

        let error: ErrorEnum

        init(_ error: ErrorEnum) {
            self.error = error
        }

        public static var badParameter: MQTTError { .init(.badParameter) }
        public static var badResponse: MQTTError { .init(.badResponse) }
    }

    enum InternalError: Swift.Error {
        case incompletePacket
    }

    enum ConnectFlags {
        static let reserved: UInt8 = 1
        static let cleanSession: UInt8 = 2
        static let willFlag: UInt8 = 4
        static let willQoSShift: UInt8 = 3
        static let willQoSMask: UInt8 = 24
        static let willRetain: UInt8 = 32
        static let password: UInt8 = 64
        static let userName: UInt8 = 128
    }

    enum PublishFlags {
        static let duplicate: UInt8 = 8
        static let retain: UInt8 = 1
        static let qosShift: UInt8 = 1
        static let qosMask: UInt8 = 6
    }

    /// calculate size of connect packet
    static func calculateConnectPacketSize(connectInfo: MQTTConnectInfo, publishInfo: MQTTPublishInfo?) -> Int {
        // variable header
        var size = 10
        // payload
        // client identifier
        size += connectInfo.clientIdentifier.utf8.count + 2
        // will publish
        if let publishInfo = publishInfo {
            // will topic
            size += publishInfo.topicName.utf8.count + 2
            // will message
            size += publishInfo.payload.readableBytes + 2
        }
        // user name
        if let userName = connectInfo.userName {
            size += userName.utf8.count + 2
        }
        // password
        if let password = connectInfo.password {
            size += password.utf8.count + 2
        }
        return size
    }

    // write connect packet
    static func writeConnect(connectInfo: MQTTConnectInfo, willInfo: MQTTPublishInfo?, to byteBuffer: inout ByteBuffer) throws {
        let length = self.calculateConnectPacketSize(connectInfo: connectInfo, publishInfo: willInfo)

        writeFixedHeader(packetType: .CONNECT, size: length, to: &byteBuffer)
        // variable header
        try writeString("MQTT", to: &byteBuffer)
        // protocol level
        byteBuffer.writeInteger(UInt8(4))
        // connect flags
        var flags = connectInfo.cleanSession ? ConnectFlags.cleanSession : 0
        if let willInfo = willInfo {
            flags |= ConnectFlags.willFlag
            flags |= willInfo.retain ? ConnectFlags.willRetain : 0
            flags |= willInfo.qos.rawValue << ConnectFlags.willQoSShift
        }
        flags |= connectInfo.password != nil ? ConnectFlags.password : 0
        flags |= connectInfo.userName != nil ? ConnectFlags.userName : 0
        byteBuffer.writeInteger(flags)
        // keep alive
        byteBuffer.writeInteger(connectInfo.keepAliveSeconds)

        // payload
        try writeString(connectInfo.clientIdentifier, to: &byteBuffer)
        if let willInfo = willInfo {
            try writeString(willInfo.topicName, to: &byteBuffer)
            var payload = willInfo.payload
            // payload size
            let length = payload.readableBytes
            guard length < 65536 else { throw MQTTError.badParameter }
            byteBuffer.writeInteger(UInt16(length))
            // payload data
            byteBuffer.writeBuffer(&payload)
        }
        if let userName = connectInfo.userName {
            try writeString(userName, to: &byteBuffer)
        }
        if let password = connectInfo.password {
            try writeString(password, to: &byteBuffer)
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
        var flags: UInt8 = publishInfo.retain ? PublishFlags.retain : 0
        flags |= publishInfo.qos.rawValue << PublishFlags.qosShift
        flags |= publishInfo.dup ? PublishFlags.duplicate : 0

        let length = self.calculatePublishPacketSize(publishInfo: publishInfo)

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
            $0 + 2 + $1.topicFilter.utf8.count + 1 // topic filter length + topic filter + qos
        }
    }

    /// write subscribe packet
    static func writeSubscribe(subscribeInfos: [MQTTSubscribeInfo], packetId: UInt16, to byteBuffer: inout ByteBuffer) throws {
        let length = self.calculateSubscribePacketSize(subscribeInfos: subscribeInfos)

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
            $0 + 2 + $1.topicFilter.utf8.count // topic filter length + topic filter
        }
    }

    /// write unsubscribe packet
    static func writeUnsubscribe(subscribeInfos: [MQTTSubscribeInfo], packetId: UInt16, to byteBuffer: inout ByteBuffer) throws {
        let length = self.calculateUnsubscribePacketSize(subscribeInfos: subscribeInfos)

        writeFixedHeader(packetType: .UNSUBSCRIBE, size: length, to: &byteBuffer)
        // write variable header
        byteBuffer.writeInteger(packetId)
        // write payload
        for info in subscribeInfos {
            try writeString(info.topicFilter, to: &byteBuffer)
        }
    }

    /// write ACK packet
    static func writeAck(packetType: MQTTPacketType, packetId: UInt16? = nil, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: packetType, size: 2, to: &byteBuffer)
        if let packetId = packetId {
            byteBuffer.writeInteger(packetId)
        }
    }

    /// write disconnect packet
    static func writeDisconnect(to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .DISCONNECT, size: 0, to: &byteBuffer)
    }

    /// write PINGREQ packet
    static func writePingreq(to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .PINGREQ, size: 0, to: &byteBuffer)
    }

    /// read publish packet
    static func readPublish(from packet: MQTTPacketInfo) throws -> (packetId: UInt16, publishInfo: MQTTPublishInfo) {
        var remainingData = packet.remainingData
        var packetId: UInt16 = 0
        // read topic name
        let topicName = try readString(from: &remainingData)
        guard let qos = MQTTQoS(rawValue: (packet.flags & PublishFlags.qosMask) >> PublishFlags.qosShift) else { throw MQTTError.badResponse }
        // read packet id if QoS is not atMostOnce
        if qos != .atMostOnce {
            guard let readPacketId: UInt16 = remainingData.readInteger() else { throw MQTTError.badResponse }
            packetId = readPacketId
        }
        // read payload
        let payload = remainingData.readSlice(length: remainingData.readableBytes) ?? MQTTPublishInfo.emptyByteBuffer
        // create publish info
        let publishInfo = MQTTPublishInfo(
            qos: qos,
            retain: packet.flags & PublishFlags.retain != 0,
            dup: packet.flags & PublishFlags.duplicate != 0,
            topicName: topicName,
            payload: payload
        )
        return (packetId: packetId, publishInfo: publishInfo)
    }

    /// read connack packet
    static func readConnack(from packet: MQTTPacketInfo) throws -> (returnCode: UInt8, sessionPresent: Bool) {
        var remainingData = packet.remainingData
        guard let bytes = remainingData.readBytes(length: 2) else { throw MQTTError.badResponse }
        return (returnCode: bytes[1], sessionPresent: bytes[0] & 0x1 == 0x1)
    }

    /// read basic ack packet (SUBACK, UNSUBACK, PUBACK, PUBREL etc)
    static func readAck(from packet: MQTTPacketInfo) throws -> UInt16 {
        var remainingData = packet.remainingData
        guard let packetId: UInt16 = remainingData.readInteger() else { throw MQTTError.badResponse }
        return packetId
    }

    /// read incoming packet
    ///
    /// read fixed header and data attached. Throws incomplete packet error if if cannot read
    /// everything
    static func readIncomingPacket(from byteBuffer: inout ByteBuffer) throws -> MQTTPacketInfo {
        guard let byte: UInt8 = byteBuffer.readInteger() else { throw InternalError.incompletePacket }
        guard let type = MQTTPacketType(rawValue: byte) ?? MQTTPacketType(rawValue: byte & 0xF0) else {
            throw MQTTError.badParameter
        }
        let length = try readLength(from: &byteBuffer)
        guard let bytes = byteBuffer.readSlice(length: length) else { throw InternalError.incompletePacket }
        return MQTTPacketInfo(type: type, flags: byte & 0xF, remainingData: bytes)
    }
}

extension MQTTSerializer {
    /// write fixed header for packet
    static func writeFixedHeader(packetType: MQTTPacketType, flags: UInt8 = 0, size: Int, to byteBuffer: inout ByteBuffer) {
        byteBuffer.writeInteger(packetType.rawValue | flags)
        self.writeLength(size, to: &byteBuffer)
    }

    /// write variable length
    static func writeLength(_ length: Int, to byteBuffer: inout ByteBuffer) {
        var length = length
        repeat {
            let byte = UInt8(length & 0x7F)
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

    /// read variable length
    static func readLength(from byteBuffer: inout ByteBuffer) throws -> Int {
        var length = 0
        var shift = 0
        repeat {
            guard let byte: UInt8 = byteBuffer.readInteger() else { throw InternalError.incompletePacket }
            length += (Int(byte) & 0x7F) << shift
            if byte & 0x80 == 0 {
                break
            }
            shift += 7
        } while true
        return length
    }

    /// read string
    static func readString(from byteBuffer: inout ByteBuffer) throws -> String {
        guard let length: UInt16 = byteBuffer.readInteger() else { throw MQTTError.badResponse }
        guard let string = byteBuffer.readString(length: Int(length)) else { throw MQTTError.badResponse }
        return string
    }
}
