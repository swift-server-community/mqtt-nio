# MQTT NIO 

A Swift NIO MQTT 3.1.1 Client. 

## Usage

Create a client with connection details and a closure to be called whenever a PUBLISH event is received

```swift
let client = MQTTClient(
    host: "mqtt.eclipse.org", 
    eventLoopGroupProvider: .createNew
)
```

Subscribe to a topic and add a publish listener to report publish messages from the server.
```swift
let subscription = MQTTSubscribeInfo(
    qos: .atLeastOnce,
    topicFilter: "my-topics"
)
try client.subscribe(infos: [subscription]).wait()
client.addPublishListener("My Listener") { result in
    switch result {
    case .success(let publish):
        var buffer = publish.payload
        let string = buffer.readString(length: buffer.readableBytes)
        print(string)
    case .failure(let error):
        print("Error while receiving PUBLISH event")
    }
}
```

Publish to a topic.
```swift
let publish = MQTTPublishInfo(
    qos: .atLeastOnce,
    retain: false,
    dup: false,
    topicName: "my-topics",
    payload: ByteBufferAllocator().buffer(string: "This is the Test payload")
)
try client.publish(info: publish).wait()
```
## WebSockets and SSL

There is support for WebSockets and TLS connections. You can enable these through the `Configuration` provided at initialization. For TLS connections set`Configuration.useSSL` to `true` and provide your SSL certificates via the `Configuration.tlsConfiguration` struct. For WebSockets set `Configuration.useWebSockets` to `true` and set the URL path in `Configuration.webSocketsURLPath`.
