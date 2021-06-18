import NIO

protocol MQTTPacket: CustomStringConvertible {
    var type: MQTTPacketType { get }
    var packetId: UInt16 { get }
    func serialize(to: inout ByteBuffer) throws
}

extension MQTTPacket {
    var packetId: UInt16 { 0 }
}

struct MQTTConnectPacket: MQTTPacket {
    var type: MQTTPacketType { .CONNECT }
    var description: String { "CONNECT" }

    let connect: MQTTConnectInfo
    let will: MQTTPublishInfo?

    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writeConnect(connectInfo: self.connect, willInfo: self.will, to: &byteBuffer)
    }
}

struct MQTTPublishPacket: MQTTPacket {
    var type: MQTTPacketType { .PUBLISH }
    var description: String { "PUBLISH" }

    let publish: MQTTPublishInfo
    let packetId: UInt16

    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writePublish(publishInfo: self.publish, packetId: self.packetId, to: &byteBuffer)
    }
}

struct MQTTSubscribePacket: MQTTPacket {
    var type: MQTTPacketType { .SUBSCRIBE }
    var description: String { "SUBSCRIBE" }

    let subscriptions: [MQTTSubscribeInfo]
    let packetId: UInt16

    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writeSubscribe(subscribeInfos: self.subscriptions, packetId: self.packetId, to: &byteBuffer)
    }
}

struct MQTTUnsubscribePacket: MQTTPacket {
    var type: MQTTPacketType { .UNSUBSCRIBE }
    var description: String { "UNSUBSCRIBE" }

    let subscriptions: [MQTTSubscribeInfo]
    let packetId: UInt16

    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writeUnsubscribe(subscribeInfos: self.subscriptions, packetId: self.packetId, to: &byteBuffer)
    }
}

struct MQTTAckPacket: MQTTPacket {
    var description: String { "ACK \(self.type)" }
    let type: MQTTPacketType
    let packetId: UInt16

    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writeAck(packetType: self.type, packetId: self.packetId, to: &byteBuffer)
    }
}

struct MQTTPingreqPacket: MQTTPacket {
    var type: MQTTPacketType { .PINGREQ }
    var description: String { "PINGREQ" }
    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writePingreq(to: &byteBuffer)
    }
}

struct MQTTPingrespPacket: MQTTPacket {
    var type: MQTTPacketType { .PINGRESP }
    var description: String { "PINGRESP" }
    
    func serialize(to: inout ByteBuffer) throws {
        try MQTTSerializer.writeAck(packetType: self.type, to: &to)
    }
}

struct MQTTDisconnectPacket: MQTTPacket {
    var type: MQTTPacketType { .DISCONNECT }
    var description: String { "DISCONNECT" }
    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writeDisconnect(to: &byteBuffer)
    }
}

struct MQTTConnAckPacket: MQTTPacket {
    var type: MQTTPacketType { .CONNACK }
    var description: String { "CONNACK" }
    let returnCode: UInt8
    let sessionPresent: Bool

    func serialize(to: inout ByteBuffer) throws {
        try MQTTSerializer.writeAck(packetType: self.type, to: &to)
    }
}
