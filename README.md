# MQTT NIO 

A Swift NIO MQTT 3.1.1 Client. 

## Usage

Create a client with connection details and a closure to be called whenever a PUBLISH event is received

```swift
let client = MQTTClient(
    host: "mqtt.eclipse.org", 
    eventLoopGroupProvider: .createNew
) { result in
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

Subscribe to a topic
```swift
let subscription = MQTTSubscribeInfo(
    qos: .atLeastOnce,
    topicFilter: "my-topics"
)
try client.subscribe(infos: [subscription]).wait()
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

There is support for WebSockets and SSL connections. You can enable these through the `Configuration` provided at initialization. I have only been able to verify these work with a small number of servers, so am not sure if the implementation of these is complete.
