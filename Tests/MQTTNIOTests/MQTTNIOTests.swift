import XCTest
import Logging
import NIO
import NIOHTTP1
import NIOSSL
@testable import MQTTNIO

final class MQTTNIOTests: XCTestCase {

    let logger: Logger = {
        var logger = Logger(label: "MQTTTests")
        logger.logLevel = .trace
        return logger
    }()

    // downloaded from http://test.mosquitto.org/
    let mosquittoCertificate = """
    -----BEGIN CERTIFICATE-----
    MIIEAzCCAuugAwIBAgIUBY1hlCGvdj4NhBXkZ/uLUZNILAwwDQYJKoZIhvcNAQEL
    BQAwgZAxCzAJBgNVBAYTAkdCMRcwFQYDVQQIDA5Vbml0ZWQgS2luZ2RvbTEOMAwG
    A1UEBwwFRGVyYnkxEjAQBgNVBAoMCU1vc3F1aXR0bzELMAkGA1UECwwCQ0ExFjAU
    BgNVBAMMDW1vc3F1aXR0by5vcmcxHzAdBgkqhkiG9w0BCQEWEHJvZ2VyQGF0Y2hv
    by5vcmcwHhcNMjAwNjA5MTEwNjM5WhcNMzAwNjA3MTEwNjM5WjCBkDELMAkGA1UE
    BhMCR0IxFzAVBgNVBAgMDlVuaXRlZCBLaW5nZG9tMQ4wDAYDVQQHDAVEZXJieTES
    MBAGA1UECgwJTW9zcXVpdHRvMQswCQYDVQQLDAJDQTEWMBQGA1UEAwwNbW9zcXVp
    dHRvLm9yZzEfMB0GCSqGSIb3DQEJARYQcm9nZXJAYXRjaG9vLm9yZzCCASIwDQYJ
    KoZIhvcNAQEBBQADggEPADCCAQoCggEBAME0HKmIzfTOwkKLT3THHe+ObdizamPg
    UZmD64Tf3zJdNeYGYn4CEXbyP6fy3tWc8S2boW6dzrH8SdFf9uo320GJA9B7U1FW
    Te3xda/Lm3JFfaHjkWw7jBwcauQZjpGINHapHRlpiCZsquAthOgxW9SgDgYlGzEA
    s06pkEFiMw+qDfLo/sxFKB6vQlFekMeCymjLCbNwPJyqyhFmPWwio/PDMruBTzPH
    3cioBnrJWKXc3OjXdLGFJOfj7pP0j/dr2LH72eSvv3PQQFl90CZPFhrCUcRHSSxo
    E6yjGOdnz7f6PveLIB574kQORwt8ePn0yidrTC1ictikED3nHYhMUOUCAwEAAaNT
    MFEwHQYDVR0OBBYEFPVV6xBUFPiGKDyo5V3+Hbh4N9YSMB8GA1UdIwQYMBaAFPVV
    6xBUFPiGKDyo5V3+Hbh4N9YSMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQEL
    BQADggEBAGa9kS21N70ThM6/Hj9D7mbVxKLBjVWe2TPsGfbl3rEDfZ+OKRZ2j6AC
    6r7jb4TZO3dzF2p6dgbrlU71Y/4K0TdzIjRj3cQ3KSm41JvUQ0hZ/c04iGDg/xWf
    +pp58nfPAYwuerruPNWmlStWAXf0UTqRtg4hQDWBuUFDJTuWuuBvEXudz74eh/wK
    sMwfu1HFvjy5Z0iMDU8PUDepjVolOCue9ashlS4EB5IECdSR2TItnAIiIwimx839
    LdUdRudafMu5T5Xma182OC0/u/xRlEm+tvKGGmfFcN0piqVl8OrSPBgIlb+1IKJE
    m/XriWr/Cq4h/JfB7NTsezVslgkBaoU=
    -----END CERTIFICATE-----
    """

    func createClient() -> MQTTClient {
        MQTTClient(
            host: "test.mosquitto.org",
            port: 1883,
            eventLoopGroupProvider: .createNew,
            logger: self.logger
        )
    }
    func createWebSocketClient() -> MQTTClient {
        MQTTClient(
            host: "test.mosquitto.org",
            port: 8080,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(useWebSockets: true, webSocketURLPath: "/mqtt")
        )
    }
    func createSSLClient() throws -> MQTTClient {
        let rootCertificate = try NIOSSLCertificate.fromPEMBytes([UInt8](mosquittoCertificate.utf8))
        let tlsConfiguration: TLSConfiguration? = TLSConfiguration.forClient(
            trustRoots: .certificates(rootCertificate)
        )
        return MQTTClient(
            host: "test.mosquitto.org",
            port: 8883,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(useSSL: true, tlsConfiguration: tlsConfiguration)
        )
    }

    func connect(to client: MQTTClient, identifier: String) throws {
        let connect = MQTTConnectInfo(
            cleanSession: true,
            keepAliveSeconds: 15,
            clientIdentifier: identifier,
            userName: "",
            password: ""
        )
        try client.connect(info: connect).wait()
    }

    func testWebsocketConnect() throws {
        let client = createWebSocketClient()
        try connect(to: client, identifier: "connect")
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testSSLConnect() throws {
        let client = try createSSLClient()
        try connect(to: client, identifier: "connect")
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS0() throws {
        let publish = MQTTPublishInfo(
            qos: .atMostOnce,
            retain: true,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )

        let client = self.createClient()
        try connect(to: client, identifier: "publisher")
        try client.publish(info: publish).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS1() throws {
        let publish = MQTTPublishInfo(
            qos: .atLeastOnce,
            retain: true,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )

        let client = self.createClient()
        try connect(to: client, identifier: "publisher")
        try client.publish(info: publish).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS2() throws {
        let publish = MQTTPublishInfo(
            qos: .exactlyOnce,
            retain: true,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )
        
        let client = self.createClient()
        try connect(to: client, identifier: "soto_publisher")
        try client.publish(info: publish).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPingreq() throws {
        let client = self.createClient()
        try connect(to: client, identifier: "soto_publisher")
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTSubscribe() throws {
        let client = self.createClient()
        try connect(to: client, identifier: "soto_client")
        try client.subscribe(infos: [.init(qos: .atLeastOnce, topicFilter: "iphone")]).wait()
        Thread.sleep(forTimeInterval: 15)
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishToClient() throws {
        var publishReceived: [MQTTPublishInfo] = []
        let publish = MQTTPublishInfo(
            qos: .atLeastOnce,
            retain: false,
            dup: false,
            topicName: "testing-noretain",
            payload: ByteBufferAllocator().buffer(string: "This is the Test payload")
        )
        let client = self.createWebSocketClient()
        try connect(to: client, identifier: "soto_publisher")
        let client2 = self.createWebSocketClient()
        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, "This is the Test payload")
                publishReceived.append(publish)
            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        try connect(to: client2, identifier: "soto_client")
        try client2.subscribe(infos: [.init(qos: .atLeastOnce, topicFilter: "testing-noretain")]).wait()
        try client.publish(info: publish).wait()
        Thread.sleep(forTimeInterval: 2)
        try client.publish(info: publish).wait()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(publishReceived.count, 2)
        try client.disconnect().wait()
        try client2.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }
}
