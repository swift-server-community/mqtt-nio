import NIO
import NIOConcurrencyHelpers

struct MQTTListeners<ReturnType> {
    typealias Listener = (Result<ReturnType, Error>) -> Void

    func notify(_ result: Result<ReturnType, Error>) {
        self.lock.withLock {
            listeners.values.forEach { listener in
                listener(result)
            }
        }
    }

    mutating func addListener(named name: String, listener: @escaping Listener) {
        self.lock.withLock {
            listeners[name] = listener
        }
    }

    mutating func removeListener(named name: String) {
        self.lock.withLock {
            listeners[name] = nil
        }
    }

    private let lock = Lock()
    private var listeners: [String: Listener] = [:]
}
