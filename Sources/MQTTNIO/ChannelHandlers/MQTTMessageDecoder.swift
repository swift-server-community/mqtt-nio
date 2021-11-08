import Logging
import NIO

/// Decode ByteBuffers into MQTT Messages
struct ByteToMQTTMessageDecoder: NIOSingleStepByteToMessageDecoder {
    mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> MQTTPacket? {
        try self.decode(buffer: &buffer)
    }

    typealias InboundOut = MQTTPacket

    let version: MQTTClient.Version

    init(version: MQTTClient.Version) {
        self.version = version
    }

    mutating func decode(buffer: inout ByteBuffer) throws -> MQTTPacket? {
        let origBuffer = buffer
        do {
            let packet = try MQTTIncomingPacket.read(from: &buffer)
            let message: MQTTPacket
            switch packet.type {
            case .PUBLISH:
                message = try MQTTPublishPacket.read(version: self.version, from: packet)
            case .CONNACK:
                message = try MQTTConnAckPacket.read(version: self.version, from: packet)
            case .PUBACK, .PUBREC, .PUBREL, .PUBCOMP:
                message = try MQTTPubAckPacket.read(version: self.version, from: packet)
            case .SUBACK, .UNSUBACK:
                message = try MQTTSubAckPacket.read(version: self.version, from: packet)
            case .PINGRESP:
                message = try MQTTPingrespPacket.read(version: self.version, from: packet)
            case .DISCONNECT:
                message = try MQTTDisconnectPacket.read(version: self.version, from: packet)
            case .AUTH:
                message = try MQTTAuthPacket.read(version: self.version, from: packet)
            default:
                throw MQTTError.decodeError
            }
            return message
        } catch InternalError.incompletePacket {
            buffer = origBuffer
            return nil
        } catch {
            throw error
        }
    }
}
