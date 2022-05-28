# ``MQTTNIO``

A Swift NIO based MQTT client

MQTTNIO is a Swift NIO based MQTT v3.1.1 and v5.0 client supporting unencrypted, WebSocket connections and TLS through both NIOSSL and NIOTransportServices.

MQTT (Message Queuing Telemetry Transport) is a lightweight messaging protocol that was developed by IBM and first released in 1999. It uses the pub/sub pattern and translates messages between devices, servers, and applications. It is commonly used in Internet of things (IoT) technologies.

## Usage

Create a client and connect to the MQTT broker.

```swift
let client = MQTTClient(
    host: "mqtt.eclipse.org",
    port: 1883,
    identifier: "My Client",
    eventLoopGroupProvider: .createNew
)
do {
    try await client.connect()
    print("Succesfully connected")
} catch {
    print("Error while connecting \(error)")
}
```

Subscribe to a topic and add a publish listener to report publish messages sent from the server/broker.
```swift
let subscription = MQTTSubscribeInfo(topicFilter: "my-topics", qos: .atLeastOnce)
_ = try await client.subscribe(to: [subscription])
let listener = client.createPublishListener()
for await result in listener {
    switch result {
    case .success(let publish):
        if publish.topicName == "my-topics" {
            var buffer = publish.payload
            let string = buffer.readString(length: buffer.readableBytes)
            print(string)
        }
    case .failure(let error):
        print("Error while receiving PUBLISH event")
    }
}
```

Publish to a topic.
```swift
try await client.publish(
    to: "my-topics",
    payload: ByteBuffer(string: "This is the Test payload"),
    qos: .atLeastOnce
)
```

MQTTClient supports both Swift concurrency and SwiftNIO `EventLoopFuture`. The above examples use Swift concurrency but there are equivalent versions of these functions that return `EventLoopFuture`s. You can find out more about Swift NIO and `EventLoopFuture` [here](https://apple.github.io/swift-nio/docs/current/NIOCore/Classes/EventLoopFuture.html).

## Topics

### Articles

- <doc:mqttnio-v5>
- <doc:mqttnio-connections>
- <doc:mqttnio-aws>

### Client

- ``MQTTClient``

### Subscribe/Publish

- ``MQTTSubscribeInfo``
- ``MQTTSuback``
- ``MQTTPublishInfo``
- ``MQTTPublishListener``
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
- ``MQTTPublishIdListener``

### V5 Authentication

- ``MQTTAuthV5``

### TLS

- ``TSTLSConfiguration``
- ``TSTLSVersion``
- ``TSCertificateVerification``
