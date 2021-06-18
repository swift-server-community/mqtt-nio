import NIO

internal enum InternalError: Swift.Error {
    case incompletePacket
    case notImplemented
}

protocol MQTTPacket: CustomStringConvertible {
    var type: MQTTPacketType { get }
    var packetId: UInt16 { get }
    func write(to: inout ByteBuffer) throws
    static func read(from: MQTTIncomingPacket) throws -> Self
}

extension MQTTPacket {
    var packetId: UInt16 { 0 }
}

extension MQTTPacket {
    /// write fixed header for packet
    func writeFixedHeader(packetType: MQTTPacketType, flags: UInt8 = 0, size: Int, to byteBuffer: inout ByteBuffer) {
        byteBuffer.writeInteger(packetType.rawValue | flags)
        Self.writeVariableLengthInteger(size, to: &byteBuffer)
    }

    /// write variable length
    static func writeVariableLengthInteger(_ value: Int, to byteBuffer: inout ByteBuffer) {
        var value = value
        repeat {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                byteBuffer.writeInteger(byte | 0x80)
            } else {
                byteBuffer.writeInteger(byte)
            }
        } while value != 0
    }

    /// write string
    static func writeString(_ string: String, to byteBuffer: inout ByteBuffer) throws {
        let length = string.utf8.count
        guard length < 65536 else { throw MQTTError.badParameter }
        byteBuffer.writeInteger(UInt16(length))
        byteBuffer.writeString(string)
    }

    /// write buffer
    static func writeBuffer(_ buffer: ByteBuffer, to byteBuffer: inout ByteBuffer) throws {
        let length = buffer.readableBytes
        guard length < 65536 else { throw MQTTError.badParameter }
        var buffer = buffer
        byteBuffer.writeInteger(UInt16(length))
        byteBuffer.writeBuffer(&buffer)
    }

    /// read variable length
    static func readVariableLengthInteger(from byteBuffer: inout ByteBuffer) throws -> Int {
        var value = 0
        var shift = 0
        repeat {
            guard let byte: UInt8 = byteBuffer.readInteger() else { throw InternalError.incompletePacket }
            value += (Int(byte) & 0x7F) << shift
            if byte & 0x80 == 0 {
                break
            }
            shift += 7
        } while true
        return value
    }

    /// read string
    static func readString(from byteBuffer: inout ByteBuffer) throws -> String {
        guard let length: UInt16 = byteBuffer.readInteger() else { throw MQTTError.badResponse }
        guard let string = byteBuffer.readString(length: Int(length)) else { throw MQTTError.badResponse }
        return string
    }
}

struct MQTTConnectPacket: MQTTPacket {
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

    var type: MQTTPacketType { .CONNECT }
    var description: String { "CONNECT" }

    let connect: MQTTConnectInfo
    let will: MQTTPublishInfo?

    func write(to byteBuffer: inout ByteBuffer) throws {
        let length = self.calculateSize()

        writeFixedHeader(packetType: .CONNECT, size: length, to: &byteBuffer)
        // variable header
        try Self.writeString("MQTT", to: &byteBuffer)
        // protocol level
        byteBuffer.writeInteger(UInt8(4))
        // connect flags
        var flags = connect.cleanSession ? ConnectFlags.cleanSession : 0
        if let will = will {
            flags |= ConnectFlags.willFlag
            flags |= will.retain ? ConnectFlags.willRetain : 0
            flags |= will.qos.rawValue << ConnectFlags.willQoSShift
        }
        flags |= connect.password != nil ? ConnectFlags.password : 0
        flags |= connect.userName != nil ? ConnectFlags.userName : 0
        byteBuffer.writeInteger(flags)
        // keep alive
        byteBuffer.writeInteger(connect.keepAliveSeconds)

        // payload
        try Self.writeString(connect.clientIdentifier, to: &byteBuffer)
        if let will = will {
            try Self.writeString(will.topicName, to: &byteBuffer)
            try Self.writeBuffer(will.payload, to: &byteBuffer)
        }
        if let userName = connect.userName {
            try Self.writeString(userName, to: &byteBuffer)
        }
        if let password = connect.password {
            try Self.writeString(password, to: &byteBuffer)
        }
    }
    
    static func read(from: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }

    /// calculate size of connect packet
    func calculateSize() -> Int {
        // variable header
        var size = 10
        // payload
        // client identifier
        size += connect.clientIdentifier.utf8.count + 2
        // will publish
        if let will = will {
            // will topic
            size += will.topicName.utf8.count + 2
            // will message
            size += will.payload.readableBytes + 2
        }
        // user name
        if let userName = connect.userName {
            size += userName.utf8.count + 2
        }
        // password
        if let password = connect.password {
            size += password.utf8.count + 2
        }
        return size
    }
}

struct MQTTPublishPacket: MQTTPacket {
    enum PublishFlags {
        static let duplicate: UInt8 = 8
        static let retain: UInt8 = 1
        static let qosShift: UInt8 = 1
        static let qosMask: UInt8 = 6
    }

    var type: MQTTPacketType { .PUBLISH }
    var description: String { "PUBLISH" }

    let publish: MQTTPublishInfo
    let packetId: UInt16

    func write(to byteBuffer: inout ByteBuffer) throws {
        var flags: UInt8 = publish.retain ? PublishFlags.retain : 0
        flags |= publish.qos.rawValue << PublishFlags.qosShift
        flags |= publish.dup ? PublishFlags.duplicate : 0

        let length = self.calculateSize()

        writeFixedHeader(packetType: .PUBLISH, flags: flags, size: length, to: &byteBuffer)
        // write variable header
        try Self.writeString(publish.topicName, to: &byteBuffer)
        if publish.qos != .atMostOnce {
            byteBuffer.writeInteger(packetId)
        }
        // write payload
        var payload = publish.payload
        byteBuffer.writeBuffer(&payload)
    }
    
    static func read(from packet: MQTTIncomingPacket) throws -> Self {
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
        return MQTTPublishPacket(publish: publishInfo, packetId: packetId)
    }

    /// calculate size of publish packet
    func calculateSize() -> Int {
        // topic name
        var size = self.publish.topicName.utf8.count
        if publish.qos != .atMostOnce {
            size += 2
        }
        // packet identifier
        size += 2
        // payload
        size += publish.payload.readableBytes
        return size
    }

}

struct MQTTSubscribePacket: MQTTPacket {
    var type: MQTTPacketType { .SUBSCRIBE }
    var description: String { "SUBSCRIBE" }

    let subscriptions: [MQTTSubscribeInfo]
    let packetId: UInt16

    func write(to byteBuffer: inout ByteBuffer) throws {
        let length = self.calculateSize()

        writeFixedHeader(packetType: .SUBSCRIBE, size: length, to: &byteBuffer)
        // write variable header
        byteBuffer.writeInteger(packetId)
        // write payload
        for info in subscriptions {
            try Self.writeString(info.topicFilter, to: &byteBuffer)
            byteBuffer.writeInteger(info.qos.rawValue)
        }
    }

    static func read(from packet: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }

    /// calculate size of subscribe packet
    func calculateSize() -> Int {
        // packet identifier
        let size = 2
        // payload
        return subscriptions.reduce(size) {
            $0 + 2 + $1.topicFilter.utf8.count + 1 // topic filter length + topic filter + qos
        }
    }

}

struct MQTTUnsubscribePacket: MQTTPacket {
    var type: MQTTPacketType { .UNSUBSCRIBE }
    var description: String { "UNSUBSCRIBE" }

    let subscriptions: [MQTTSubscribeInfo]
    let packetId: UInt16

    func write(to byteBuffer: inout ByteBuffer) throws {
        let length = self.calculateSize()

        writeFixedHeader(packetType: .UNSUBSCRIBE, size: length, to: &byteBuffer)
        // write variable header
        byteBuffer.writeInteger(packetId)
        // write payload
        for info in subscriptions {
            try Self.writeString(info.topicFilter, to: &byteBuffer)
        }
    }

    static func read(from packet: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }

    /// calculate size of subscribe packet
    func calculateSize() -> Int {
        // packet identifier
        let size = 2
        // payload
        return subscriptions.reduce(size) {
            $0 + 2 + $1.topicFilter.utf8.count // topic filter length + topic filter
        }
    }
}

struct MQTTAckPacket: MQTTPacket {
    var description: String { "ACK \(self.type)" }
    let type: MQTTPacketType
    let packetId: UInt16

    func write(to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: type, size: 2, to: &byteBuffer)
        byteBuffer.writeInteger(packetId)
    }

    static func read(from packet: MQTTIncomingPacket) throws -> Self {
        var remainingData = packet.remainingData
        guard let packetId: UInt16 = remainingData.readInteger() else { throw MQTTError.badResponse }
        return MQTTAckPacket(type: packet.type, packetId: packetId)
    }
}

struct MQTTPingreqPacket: MQTTPacket {
    var type: MQTTPacketType { .PINGREQ }
    var description: String { "PINGREQ" }
    func write(to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .PINGREQ, size: 0, to: &byteBuffer)
    }

    static func read(from packet: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }
}

struct MQTTPingrespPacket: MQTTPacket {
    var type: MQTTPacketType { .PINGRESP }
    var description: String { "PINGRESP" }

    func write(to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: type, size: 0, to: &byteBuffer)
    }

    static func read(from packet: MQTTIncomingPacket) throws -> Self {
        return MQTTPingrespPacket()
    }
}

struct MQTTDisconnectPacket: MQTTPacket {
    var type: MQTTPacketType { .DISCONNECT }
    var description: String { "DISCONNECT" }
    func write(to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: type, size: 0, to: &byteBuffer)
    }

    static func read(from packet: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }
}

struct MQTTConnAckPacket: MQTTPacket {
    var type: MQTTPacketType { .CONNACK }
    var description: String { "CONNACK" }
    let returnCode: UInt8
    let sessionPresent: Bool

    func write(to: inout ByteBuffer) throws {
        throw InternalError.notImplemented
    }

    static func read(from packet: MQTTIncomingPacket) throws -> Self {
        var remainingData = packet.remainingData
        guard let bytes = remainingData.readBytes(length: 2) else { throw MQTTError.badResponse }
        return MQTTConnAckPacket(returnCode: bytes[1], sessionPresent: bytes[0] & 0x1 == 0x1)
    }
}

/// MQTT incoming packet parameters.
struct MQTTIncomingPacket: MQTTPacket {
    var description: String { "Incoming Packet 0x\(String(format: "%x", type.rawValue))" }
    
    /// Type of incoming MQTT packet.
    let type: MQTTPacketType

    /// packet flags
    let flags: UInt8

    /// Remaining serialized data in the MQTT packet.
    let remainingData: ByteBuffer

    func write(to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: type, flags: flags, size: remainingData.readableBytes, to: &byteBuffer)
        var buffer = self.remainingData
        byteBuffer.writeBuffer(&buffer)
    }

    static func read(from packet: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }

    /// read incoming packet
    ///
    /// read fixed header and data attached. Throws incomplete packet error if if cannot read
    /// everything
    static func read(from byteBuffer: inout ByteBuffer) throws -> MQTTIncomingPacket {
        guard let byte: UInt8 = byteBuffer.readInteger() else { throw InternalError.incompletePacket }
        guard let type = MQTTPacketType(rawValue: byte) ?? MQTTPacketType(rawValue: byte & 0xF0) else {
            throw MQTTError.badParameter
        }
        let length = try readVariableLengthInteger(from: &byteBuffer)
        guard let bytes = byteBuffer.readSlice(length: length) else { throw InternalError.incompletePacket }
        return MQTTIncomingPacket(type: type, flags: byte & 0xF, remainingData: bytes)
    }
}
