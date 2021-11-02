
import NIO

/// Class encapsulating a single task
final class MQTTTask {
    let promise: EventLoopPromise<MQTTPacket>
    let checkInbound: (MQTTPacket) throws -> Bool
    let timeoutTask: Scheduled<Void>?

    init(on eventLoop: EventLoop, timeout: TimeAmount?, checkInbound: @escaping (MQTTPacket) throws -> Bool) {
        let promise = eventLoop.makePromise(of: MQTTPacket.self)
        self.promise = promise
        self.checkInbound = checkInbound
        if let timeout = timeout {
            self.timeoutTask = eventLoop.scheduleTask(in: timeout) {
                promise.fail(MQTTError.timeout)
            }
        } else {
            self.timeoutTask = nil
        }
    }

    func succeed(_ response: MQTTPacket) {
        self.timeoutTask?.cancel()
        self.promise.succeed(response)
    }

    func fail(_ error: Error) {
        self.timeoutTask?.cancel()
        self.promise.fail(error)
    }
}
