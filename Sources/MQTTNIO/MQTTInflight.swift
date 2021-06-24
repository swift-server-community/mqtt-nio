import NIO
import NIOConcurrencyHelpers

/// Array of inflight packets. Used to resend packets when reconnecting to server
struct MQTTInflight {
    init() {
        self.lock = Lock()
        self.packets = .init(initialCapacity: 4)
    }

    /// add packet
    mutating func add(packet: MQTTPacket) {
        self.lock.withLock {
            packets.append(packet)
        }
    }

    /// remove packert
    mutating func remove(id: UInt16) {
        self.lock.withLock {
            guard let first = packets.firstIndex(where: { $0.packetId == id }) else { return }
            packets.remove(at: first)
        }
    }

    /// remove all packets
    mutating func clear() {
        self.lock.withLock {
            packets = []
        }
    }

    private let lock: Lock
    private(set) var packets: CircularBuffer<MQTTPacket>
}
