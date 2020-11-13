import XCTest
@testable import MQTTNIO

final class MQTTNIOTests: XCTestCase {
    func testExample() throws {
        let server = try EchoServer()
        let client = try EchoClient()
        let result = try client.post("This is a test").promise.futureResult.wait()
        print(result)
        //try client.post("This is the second test")
        try server.syncShutdownGracefully()
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
