import NIO
import NIOConcurrencyHelpers

struct MQTTInflight {
    init() {
        self.lock = Lock()
        self.packets = .init(initialCapacity: 4)
    }

    mutating func add(packet: MQTTPacket) {
        lock.withLock {
            packets.append(packet)
        }
    }

    mutating func remove(id: UInt16) {
        lock.withLock {
            guard let first = packets.firstIndex(where: { $0.packetId == id }) else { return }
            packets.remove(at: first)
        }
    }

    mutating func clear() {
        lock.withLock {
            packets = []
        }
    }

    private let lock: Lock
    private(set) var packets: CircularBuffer<MQTTPacket>
}
