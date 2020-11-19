# MQTT NIO 

A Swift NIO based MQTT 3.1.1 Client. 

## Usage

Create a client and connect to the MQTT broker.  

```swift
let client = MQTTClient(
    host: "mqtt.eclipse.org", 
    port: 1883,
    eventLoopGroupProvider: .createNew
)
let connectInfo = MQTTConnectInfo(
    cleanSession: true,
    keepAliveSeconds: 15,
    clientIdentifier: identifier
)
try client.connect(info: connect).wait()
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
    topicName: "my-topics",
    payload: ByteBufferAllocator().buffer(string: "This is the Test payload")
)
try client.publish(info: publish).wait()
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
    eventLoopGroupProvider: .createNew,
    configuration: .init(useSSL: true, tlsConfiguration: tlsConfiguration),
)
```

## WebSockets

MQTT also supports Web Socket connections. Set `Configuration.useWebSockets` to `true` and set the URL path in `Configuration.webSocketsURLPath` to enable these.
