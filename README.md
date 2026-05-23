# MQTT NIO

[![sswg:sandbox|94x20](https://img.shields.io/badge/sswg-sandbox-lightgrey.svg)](https://github.com/swift-server/sswg/blob/master/process/incubation.md#sandbox-level)
[<img src="https://img.shields.io/badge/swift-6.2-brightgreen.svg" alt="Swift 6.2" />](https://swift.org)
[<img src="https://github.com/swift-server-community/mqtt-nio/workflows/CI/badge.svg" />](https://github.com/swift-server-community/mqtt-nio/workflows/CI/badge.svg)
![Codecov](https://img.shields.io/codecov/c/github/swift-server-community/mqtt-nio)

A Swift NIO based MQTT v3.1.1 and v5.0 client.

MQTT (Message Queuing Telemetry Transport) is a lightweight messaging protocol that was developed by IBM and first released in 1999. It uses the pub/sub pattern and translates messages between devices, servers, and applications. It is commonly used in Internet of things (IoT) technologies.

MQTTNIO is a Swift NIO based implementation of a MQTT client. It supports
- MQTT versions 3.1.1 and 5.0.
- Unencrypted and encrypted (via TLS) connections
- WebSocket connections
- Posix sockets
- Apple's Network framework via [NIOTransportServices](https://github.com/apple/swift-nio-transport-services) (required for iOS).
- Unix domain sockets

## Overview

Create a connection to the MQTT broker with `MQTTConnection.withConnection` and use it inside the closure.
When the closure returns the connection will be closed.

```swift
try await MQTTConnection.withConnection(
    address: .hostname("mqtt.eclipse.org"),
    identifier: "My Client",
    logger: Logger(...)
) { connection in
    // You are now connected to the MQTT broker
    // The connection will be active only inside this closure
}
```

Subscribe to a topic with `MQTTConnection.subscribe`,
providing a closure that receives an `AsyncSequence` of incoming `PUBLISH` messages sent from the broker to that topic.
When the closure finishes executing, the corresponding `UNSUBSCRIBE` message is automatically sent to the broker, and the subscription is cleaned up.

```swift
let subscribeInfo = MQTTSubscribeInfo(topicFilter: "my-topics", qos: .atLeastOnce)
try await connection.subscribe(to: [subscribeInfo]) { subscription in
    for try await message in subscription {
        var buffer = message.payload
        let string = buffer.readString(length: buffer.readableBytes)
        // No need to filter messages, as only messages for "my-topics" are received here
        print(string)
    }
}
```

Publish to a topic with `MQTTConnection.publish`.

```swift
try await connection.publish(
    to: "my-topics",
    payload: ByteBuffer(string: "This is the Test payload"),
    qos: .atLeastOnce
)
```

## Documentation

User guides and reference documentation for MQTT NIO can be found on the [Swift Package Index](https://swiftpackageindex.com/swift-server-community/mqtt-nio/documentation/mqttnio).
There is also a sample demonstrating the use of MQTTNIO v2 in an iOS app found [here](https://github.com/adam-fowler/EmCuTeeTee).
