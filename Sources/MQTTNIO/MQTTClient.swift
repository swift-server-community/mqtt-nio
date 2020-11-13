import NIO
import NIOConcurrencyHelpers

class MQTTClient {
    enum Error: Swift.Error {
        case failedToConnect
    }
    let eventLoopGroup: EventLoopGroup
    static let globalPacketId = NIOAtomic<UInt16>.makeAtomic(value: 0)

    init() throws {
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func connect(info: MQTTConnectInfo, will: MQTTPublishInfo? = nil) -> EventLoopFuture<Void> {
        sendMessage(MQTTConnectMessage(connect: info, will: nil)).flatMapThrowing { response in
            guard response.type == .CONNACK else { throw Error.failedToConnect }
        }
    }

    func publish(info: MQTTPublishInfo) -> EventLoopFuture<Void> {
        sendMessage(MQTTPublishMessage(publish: info, packetId: Self.globalPacketId.add(1))).flatMapThrowing { response in
            guard response.type == .PUBACK else { throw Error.failedToConnect }
        }
    }

    func sendMessage(_ message: MQTTOutboundMessage) -> EventLoopFuture<MQTTInboundMessage> {
        let task = Task<MQTTInboundMessage>(on: eventLoopGroup.next())
        let taskHandler = TaskHandler(task: task)

        ClientBootstrap(group: eventLoopGroup)
            // Enable SO_REUSEADDR.
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([MQTTClientHandler(), taskHandler])
            }
            .connect(host: "test.mosquitto.org", port: 1883)
            .flatMap { channel in
                channel.writeAndFlush(message)
            }.whenFailure { error in
                task.fail(error)
            }
        return task.promise.futureResult
    }

    func syncShutdownGracefully() throws {
        try eventLoopGroup.syncShutdownGracefully()
    }
}
