import NIOConcurrencyHelpers

struct MQTTInflight {
    init() {
        self.lock = Lock()
        self.packets = [:]
    }

    mutating func add(id: UInt16, packet: MQTTPacket) {
        lock.withLock {
            packets[id] = packet
        }
    }

    mutating func remove(id: UInt16) {
        lock.withLock {
            packets[id] = nil
        }
    }

    func map<T>(_ transform: (UInt16, MQTTPacket) -> T) -> [T] {
        var result: [T] = []
        result.reserveCapacity(packets.count)
        lock.withLock {
            for p in packets {
                result.append(transform(p.key, p.value))
            }
        }
        return result
    }

    private let lock: Lock
    private var packets: [UInt16: MQTTPacket]
}
