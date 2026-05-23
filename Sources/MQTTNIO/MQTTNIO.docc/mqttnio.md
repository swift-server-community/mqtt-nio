# ``MQTTNIO``

A Swift NIO based v3.1.1 and v5.0 MQTT client.

## Overview

MQTT (Message Queuing Telemetry Transport) is a lightweight messaging protocol that was developed by IBM and first released in 1999. It uses the pub/sub pattern and translates messages between devices, servers, and applications. It is commonly used in Internet of things (IoT) technologies.

MQTTNIO is a Swift NIO based implementation of a MQTT client. It supports

- MQTT versions 3.1.1 and 5.0.
- Unencrypted and encrypted (via TLS) connections
- WebSocket connections
- Posix sockets
- Apple's Network framework via [NIOTransportServices](https://github.com/apple/swift-nio-transport-services) (required for iOS).
- Unix domain sockets

### Usage

Create a connection to the MQTT broker with ``MQTTConnection/withConnection(address:configuration:identifier:eventLoop:logger:operation:)-(_,_,_,_,_,(MQTTConnection)->Value)`` and use it inside the closure.
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

Subscribe to a topic with ``MQTTConnection/subscribe(to:process:)``,
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

Publish to a topic with ``MQTTConnection/publish(to:payload:qos:retain:)``.

```swift
try await connection.publish(
    to: "my-topics",
    payload: ByteBuffer(string: "This is the Test payload"),
    qos: .atLeastOnce
)
```

## Topics

### Articles

- <doc:mqttnio-v5>
- <doc:mqttnio-connections>
- <doc:mqttnio-sessions>
- <doc:mqttnio-aws>

### Connection

- ``MQTTConnection``
- ``MQTTConnectionConfiguration``
- ``MQTTServerAddress``
- ``MQTTSession``

### Subscribe/Publish

- ``MQTTSubscription``
- ``MQTTSubscribeInfo``
- ``MQTTSuback``
- ``MQTTPublishInfo``
- ``MQTTQoS``
- ``MQTTPacketType``

### Errors

- ``MQTTError``
- ``MQTTPacketError``

### V5 Connection

- ``MQTTConnackV5``

### V5 Subscribe/Publish

- ``MQTTSubscribeInfoV5``
- ``MQTTProperties``
- ``MQTTReasonCode``
- ``MQTTAckV5``
- ``MQTTSubackV5``

### V5 Authentication

- ``MQTTAuthenticator``
- ``MQTTAuthV5``

### TLS

- ``TSTLSConfiguration``
- ``TSTLSVersion``
- ``TSCertificateVerification``
