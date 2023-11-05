import Logging
import MQTTNIO
import NIOTransportServices

func test() async throws {
    if #available(macOS 12.0, *) {
        var logger = Logger(label: "MQTT")
        logger.logLevel = .trace
        let mqttClient = MQTTClient(
            host: "localhost",
            port: 1883,
            identifier: "test",
            eventLoopGroupProvider: .shared(NIOTSEventLoopGroup.singleton),
            logger: logger,
            configuration: .init()
        )
        logger.info("Connecting")
        do {
            try await mqttClient.connect()
            await withCheckedContinuation { cont in
                mqttClient.addCloseListener(named: "wait") { _ in
                    logger.info("Closed")
                    cont.resume()
                }
            }
        } catch {}
        try await mqttClient.shutdown()
    }
}

try await test()
