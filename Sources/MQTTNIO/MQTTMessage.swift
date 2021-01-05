import NIO

protocol MQTTOutboundMessage: CustomStringConvertible {
    var type: MQTTPacketType { get }
    func serialize(to: inout ByteBuffer) throws
}

protocol MQTTInboundMessage: CustomStringConvertible {
    var type: MQTTPacketType { get }
    var packetId: UInt16 { get }
}

protocol MQTTOutboundWithPacketIdMessage: MQTTOutboundMessage {
    var packetId: UInt16 { get }
}


struct MQTTConnectMessage: MQTTOutboundMessage {
    var type: MQTTPacketType { .CONNECT }
    var description: String { "CONNECT" }

    let connect: MQTTConnectInfo
    let will: MQTTPublishInfo?

    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writeConnect(connectInfo: connect, willInfo: will, to: &byteBuffer)
    }
}

struct MQTTPublishMessage: MQTTOutboundWithPacketIdMessage, MQTTInboundMessage {
    var type: MQTTPacketType { .PUBLISH }
    var description: String { "PUBLISH" }

    let publish: MQTTPublishInfo
    let packetId: UInt16

    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writePublish(publishInfo: publish, packetId: packetId, to: &byteBuffer)
    }
}

struct MQTTSubscribeMessage: MQTTOutboundWithPacketIdMessage {
    var type: MQTTPacketType { .SUBSCRIBE }
    var description: String { "SUBSCRIBE" }

    let subscriptions: [MQTTSubscribeInfo]
    let packetId: UInt16

    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writeSubscribe(subscribeInfos: subscriptions, packetId: packetId, to: &byteBuffer)
    }
}

struct MQTTUnsubscribeMessage: MQTTOutboundWithPacketIdMessage {
    var type: MQTTPacketType { .UNSUBSCRIBE }
    var description: String { "UNSUBSCRIBE" }

    let subscriptions: [MQTTSubscribeInfo]
    let packetId: UInt16

    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writeUnsubscribe(subscribeInfos: subscriptions, packetId: packetId, to: &byteBuffer)
    }
}

struct MQTTAckMessage: MQTTOutboundWithPacketIdMessage, MQTTInboundMessage {
    var description: String { "ACK \(type)" }
    let type: MQTTPacketType
    let packetId: UInt16

    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writeAck(packetType: type, packetId: packetId, to: &byteBuffer)
    }
}

struct MQTTPingreqMessage: MQTTOutboundMessage {
    var type: MQTTPacketType { .PINGREQ }
    var description: String { "PINGREQ" }
    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writePingreq(to: &byteBuffer)
    }
}

struct MQTTPingrespMessage: MQTTInboundMessage {
    var type: MQTTPacketType { .PINGRESP }
    var description: String { "PINGRESP" }
    var packetId: UInt16 { 0 }
}

struct MQTTDisconnectMessage: MQTTOutboundMessage {
    var type: MQTTPacketType { .DISCONNECT }
    var description: String { "DISCONNECT" }
    func serialize(to byteBuffer: inout ByteBuffer) throws {
        try MQTTSerializer.writeDisconnect(to: &byteBuffer)
    }
}

struct MQTTConnAckMessage: MQTTInboundMessage {
    var type: MQTTPacketType { .CONNACK }
    var description: String { "CONNACK" }
    let packetId: UInt16
    let sessionPresent: Bool
}


