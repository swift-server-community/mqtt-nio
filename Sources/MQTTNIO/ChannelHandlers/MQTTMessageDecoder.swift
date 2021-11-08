import Logging
import NIO

/// Decode ByteBuffers into MQTT Messages
struct ByteToMQTTMessageDecoder: NIOSingleStepByteToMessageDecoder {
    mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> MQTTPacket? {
        try self.decode(buffer: &buffer)
    }

    typealias InboundOut = MQTTPacket

    let client: MQTTClient

    init(client: MQTTClient) {
        self.client = client
    }

    mutating func decode(buffer: inout ByteBuffer) throws -> MQTTPacket? {
        let origBuffer = buffer
        do {
            let packet = try MQTTIncomingPacket.read(from: &buffer)
            let message: MQTTPacket
            switch packet.type {
            case .PUBLISH:
                message = try MQTTPublishPacket.read(version: self.client.configuration.version, from: packet)
            case .CONNACK:
                message = try MQTTConnAckPacket.read(version: self.client.configuration.version, from: packet)
            case .PUBACK, .PUBREC, .PUBREL, .PUBCOMP:
                message = try MQTTPubAckPacket.read(version: self.client.configuration.version, from: packet)
            case .SUBACK, .UNSUBACK:
                message = try MQTTSubAckPacket.read(version: self.client.configuration.version, from: packet)
            case .PINGRESP:
                message = try MQTTPingrespPacket.read(version: self.client.configuration.version, from: packet)
            case .DISCONNECT:
                message = try MQTTDisconnectPacket.read(version: self.client.configuration.version, from: packet)
            case .AUTH:
                message = try MQTTAuthPacket.read(version: self.client.configuration.version, from: packet)
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
