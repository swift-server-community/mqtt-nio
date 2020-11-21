# MQTT NIO 

[<img src="http://img.shields.io/badge/swift-5.3-brightgreen.svg" alt="Swift 5.3" />](https://swift.org)
[<img src="https://github.com/adam-fowler/mqtt-nio/workflows/CI/badge.svg" />](https://github.com/adam-fowler/mqtt-nio/workflows/CI/badge.svg)

A Swift NIO based MQTT 3.1.1 Client. 

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
try client.connect().wait()
```

Subscribe to a topic and add a publish listener to report publish messages from the server.
```swift
let subscription = MQTTSubscribeInfo(
    topicFilter: "my-topics",
    qos: .atLeastOnce
)
try client.subscribe(to: [subscription]).wait()
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
try client.publish(
    to: "my-topics",
    payload: ByteBufferAllocator().buffer(string: "This is the Test payload"),
    qos: .atLeastOnce
).wait()
```
## TLS

MQTT NIO supports TLS connections. You can enable this through the `Configuration` provided at initialization. Set`Configuration.useSSL` to `true` and provide your SSL certificates via the `Configuration.tlsConfiguration` struct. For example to connect to the mosquitto test server `test.mosquitto.org` on port 8884 you need to provide their root certificate and your own certificate. They provide details on the website [https://test.mosquitto.org/](https://test.mosquitto.org/) on how to generate these.

```swift
let rootCertificate = try NIOSSLCertificate.fromPEMBytes([UInt8](mosquittoCertificateText.utf8))
let myCertificate = try NIOSSLCertificate.fromPEMBytes([UInt8](myCertificateText.utf8))
let myPrivateKey = try NIOSSLPrivateKey(bytes: [UInt8](myPrivateKeyText.utf8), format: .pem)
let tlsConfiguration: TLSConfiguration? = TLSConfiguration.forClient(
    trustRoots: .certificates(rootCertificate),
    certificateChain: myCertificate.map { .certificate($0) },
    privateKey: .privateKey(myPrivateKey)
)
let client = MQTTClient(
    host: "test.mosquitto.org",
    port: 8884,
    identifier: "MySSLClient",
    eventLoopGroupProvider: .createNew,
    configuration: .init(useSSL: true, tlsConfiguration: tlsConfiguration),
)
```
Currently trustRoots and client certificates are not fully supported on iOS. 
## WebSockets

MQTT also supports Web Socket connections. Set `Configuration.useWebSockets` to `true` and set the URL path in `Configuration.webSocketsURLPath` to enable these.
