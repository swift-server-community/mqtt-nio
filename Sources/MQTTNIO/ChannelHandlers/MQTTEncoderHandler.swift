import Logging
import NIO

/// Handler encoding MQTT Messages into ByteBuffers
final class MQTTEncodeHandler: ChannelOutboundHandler {
    public typealias OutboundIn = MQTTPacket
    public typealias OutboundOut = ByteBuffer

    let client: MQTTClient

    init(client: MQTTClient) {
        self.client = client
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        self.client.logger.trace("MQTT Out", metadata: ["mqtt_message": .string("\(message)"), "mqtt_packet_id": .string("\(message.packetId)")])
        var bb = context.channel.allocator.buffer(capacity: 0)
        do {
            try message.write(version: self.client.configuration.version, to: &bb)
            context.write(wrapOutboundOut(bb), promise: promise)
        } catch {
            promise?.fail(error)
        }
    }
}
