import NIO
import NIOConcurrencyHelpers
import NIOSSL

public class MQTTClient {
    enum Error: Swift.Error {
        case alreadyConnected
        case failedToConnect
        case noConnection
        case unexpectedMessage
        case decodeError
    }
    let eventLoopGroup: EventLoopGroup
    let host: String
    let port: Int
    let publishCallback: (MQTTPublishInfo) -> ()
    let ssl: Bool
    var channel: Channel?
    var clientIdentifier = ""

    static let globalPacketId = NIOAtomic<UInt16>.makeAtomic(value: 1)

    public init(host: String, port: Int? = nil, ssl: Bool = false, tlsConfiguration: TLSConfiguration? = TLSConfiguration.forClient(), publishCallback: @escaping (MQTTPublishInfo) -> () = { _ in }) throws {
        self.host = host
        self.ssl = ssl
        if let port = port {
            self.port = port
        } else {
            if ssl {
                self.port = 8883
            } else {
                self.port = 1883
            }
        }
        self.publishCallback = publishCallback
        self.channel = nil
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func connect(info: MQTTConnectInfo, will: MQTTPublishInfo? = nil) -> EventLoopFuture<Void> {
        guard self.channel == nil else { return eventLoopGroup.next().makeFailedFuture(Error.alreadyConnected) }
        return createBootstrap()
            .flatMap { channel -> EventLoopFuture<MQTTInboundMessage> in
                self.clientIdentifier = info.clientIdentifier
                return self.sendMessage(MQTTConnectMessage(connect: info, will: nil)) { message in
                    guard message.type == .CONNACK else { throw Error.failedToConnect }
                    return true
                }
            }
            .map { _ in }
    }

    public func publish(info: MQTTPublishInfo) -> EventLoopFuture<Void> {
        let packetId = Self.globalPacketId.add(1)
        return sendMessage(MQTTPublishMessage(publish: info, packetId: packetId)) { message in
            guard message.packetId == packetId else { return false }
            if info.qos == .atLeastOnce {
                guard message.type == .PUBACK else { throw Error.unexpectedMessage }
            } else if info.qos == .exactlyOnce {
                guard message.type == .PUBREC else { throw Error.unexpectedMessage }
            }
            return true
        }
        .flatMap { _ in
            if info.qos == .exactlyOnce {
                return self.sendMessage(MQTTAckMessage(type: .PUBREL, packetId: packetId)) { message in
                    guard message.packetId == packetId else { return false }
                    guard message.type == .PUBCOMP else { throw Error.unexpectedMessage }
                    return true
                }.map { _ in }
            }
            return self.eventLoopGroup.next().makeSucceededFuture(())
        }
    }

    public func subscribe(infos: [MQTTSubscribeInfo]) -> EventLoopFuture<Void> {
        let packetId = Self.globalPacketId.add(1)
        return sendMessage(MQTTSubscribeMessage(subscriptions: infos, packetId: packetId)) { message in
            guard message.packetId == packetId else { return false }
            guard message.type == .SUBACK else { throw Error.unexpectedMessage }
            return true
        }
        .map { _ in }
    }

    public func unsubscribe(infos: [MQTTSubscribeInfo]) -> EventLoopFuture<Void> {
        let packetId = Self.globalPacketId.add(1)
        return sendMessage(MQTTUnsubscribeMessage(subscriptions: infos, packetId: packetId)) { message in
            guard message.packetId == packetId else { return false }
            guard message.type == .UNSUBACK else { throw Error.unexpectedMessage }
            return true
        }
        .map { _ in }
    }

    public func pingreq() -> EventLoopFuture<Void> {
        return sendMessage(MQTTPingreqMessage()) { message in
            guard message.type == .PINGRESP else { return false }
            return true
        }
        .map { _ in }
    }
    
    public func disconnect() -> EventLoopFuture<Void> {
        let disconnect: EventLoopFuture<Void> = sendMessageNoWait(MQTTDisconnectMessage())
            .flatMap {
                let future = self.channel!.close()
                self.channel = nil
                return future
            }
        return disconnect
    }

    public func read() throws {
        guard let channel = self.channel else { throw Error.noConnection }
        return channel.read()
    }
}

extension MQTTClient {
    func getSSLHandler() -> [ChannelHandler] {
        if ssl {
            do {
                let tlsConfiguration = TLSConfiguration.forClient()
                let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
                let tlsHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                return [tlsHandler]
            } catch {
                return []
            }
        } else {
            return []
        }
    }
    
    func createBootstrap() -> EventLoopFuture<Channel> {
        
        ClientBootstrap(group: eventLoopGroup)
            // Enable SO_REUSEADDR.
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.autoRead, value: true)
            .channelInitializer { channel in
                channel.pipeline.addHandlers(self.getSSLHandler() + [
                    MQTTEncodeHandler(client: self),
                    ByteToMessageHandler(ByteToMQTTMessageDecoder(client: self))
                ])
            }
            .connect(host: self.host, port: self.port)
            .map { channel in
                self.channel = channel
                channel.closeFuture.whenComplete { _ in
                    self.channel = nil
                }
                return channel
            }
    }
    
    func sendMessage(_ message: MQTTOutboundMessage, checkInbound: @escaping (MQTTInboundMessage) throws -> Bool) -> EventLoopFuture<MQTTInboundMessage> {
        guard let channel = self.channel else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
        let task = MQTTTask(on: eventLoopGroup.next(), checkInbound: checkInbound)
        let taskHandler = MQTTTaskHandler(task: task, channel: channel)

        channel.pipeline.addHandler(taskHandler)
            .flatMap {
                channel.writeAndFlush(message)
            }
            .whenFailure { error in
                task.fail(error)
            }
        return task.promise.futureResult
    }

    func sendMessageNoWait(_ message: MQTTOutboundMessage) -> EventLoopFuture<Void> {
        guard let channel = self.channel else { return eventLoopGroup.next().makeFailedFuture(Error.noConnection) }
        return channel.writeAndFlush(message)
    }
    
    func syncShutdownGracefully() throws {
        try channel?.close().wait()
        try eventLoopGroup.syncShutdownGracefully()
    }

}
