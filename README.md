# MQTT NIO 

[![sswg:sandbox|94x20](https://img.shields.io/badge/sswg-sandbox-lightgrey.svg)](https://github.com/swift-server/sswg/blob/master/process/incubation.md#sandbox-level)
[<img src="http://img.shields.io/badge/swift-5.5-brightgreen.svg" alt="Swift 5.5" />](https://swift.org)
[<img src="https://github.com/adam-fowler/mqtt-nio/workflows/CI/badge.svg" />](https://github.com/adam-fowler/mqtt-nio/workflows/CI/badge.svg)

A Swift NIO based MQTT v3.1.1 and v5.0 client supporting NIOTransportServices (required for iOS), WebSocket connections and TLS through both NIOSSL and NIOTransportServices.

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
client.connect().whenComplete { result in
    switch result {
    case .success:
        print("Succesfully connected")
    case .failure(let error):
        print("Error while connecting \(error)")
    }
}
```

Subscribe to a topic and add a publish listener to report publish messages sent from the server/broker.
```swift
let subscription = MQTTSubscribeInfo(topicFilter: "my-topics", qos: .atLeastOnce)
client.subscribe(to: [subscription]).whenComplete { result in
    ...
}
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
client.publish(
    to: "my-topics",
    payload: ByteBuffer(string: "This is the Test payload"),
    qos: .atLeastOnce
).whenComplete { result in
    ...
}
```
Each MQTTClient function returns a Swift NIO `EventLoopFuture`. In the examples above I just use `whenComplete` to process the results, but you can use various methods to chain `EventLoopFuture` together. You can find out more about Swift NIO [here](https://apple.github.io/swift-nio/docs/current/NIO/Classes/EventLoopFuture.html).

## Swift Concurrency

Alongside the `EventLoopFuture` APIs MQTTNIO also includes async/await versions. So where with `EventLoopFutures` you would write
```swift
client.connect()
    .flatMap { _ -> EventLoopFuture<MQTTSuback> in
        let subscription = MQTTSubscribeInfo(topicFilter: "my-topics", qos: .atLeastOnce)
        return client.subscribe(to: [subscription])
    }
    .whenComplete { result in
        doStuff()
    }
```
you can now replace it with
```swift
_ = try await client.connect()
let subscription = MQTTSubscribeInfo(topicFilter: "my-topics", qos: .atLeastOnce)
_ = try await client.subscribe(to: [subscription])
doStuff()
```

### PUBLISH listener AsyncSequence
If you don't want to parse incoming PUBLISH packets via a callback the Swift concurrency support also includes an `AsyncSequence` for this purpose. 
```swift
let listener = client.createPublishListener()
for await result in listener {
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
    configuration: .init(useSSL: true, tlsConfiguration: .niossl(tlsConfiguration)),
)
```

## WebSockets

MQTT also supports Web Socket connections. Set `Configuration.useWebSockets` to `true` and set the URL path in `Configuration.webSocketsURLPath` to enable these.

## NIO Transport Services

On macOS and iOS you can use the NIO Transport Services library (NIOTS) and Apple's `Network.framework` for communication with the MQTT broker. If you don't provide an `eventLoopGroup` or a `TLSConfigurationType` then this is the default for both platforms. If you do provide either of these then the library will base it's decision on whether to use NIOTS or NIOSSL on what you provide. Provide a `MultiThreadedEventLoopGroup` or `NIOSSL.TLSConfiguration` and the client will use NIOSSL. Provide a `NIOTSEventLoopGroup` or `TSTLSConfiguration` and the client will use NIOTS. If you provide a `MultiThreadedEventLoopGroup` and a `TSTLSConfiguration` then the client will throw an error. If you are running on iOS you should always choose NIOTS. 

## AWS IoT

The MQTT client can be used to connect to AWS IoT brokers. You can use both a WebSocket connection authenticated using AWS Signature V4 and a standard connection using a X.509 client certificate. If you are using a X.509 certificate make sure you update the attached role to allow your client id to connect and which topics you can subscribe, publish to.

If you are using an AWS Signature V4 authenticated WebSocket connection you can use the V4 signer from [SotoCore](https://github.com/soto-project/soto) to sign your initial request as follows
```swift
import SotoSignerV4

let host = "MY_AWS_IOT_ENDPOINT.iot.eu-west-1.amazonaws.com"
let headers = HTTPHeaders([("host", host)])
let signer = AWSSigner(
    credentials: StaticCredential(accessKeyId: "MYACCESSKEY", secretAccessKey: "MYSECRETKEY"), 
    name: "iotdata", 
    region: "eu-west-1"
)
let signedURL = signer.signURL(
    url: URL(string: "https://\(host)/mqtt")!, 
    method: .GET, 
    headers: headers, 
    body: .none, 
    expires: .minutes(30)
)
let requestURI = "/mqtt?\(signedURL.query!)"
let client = MQTTClient(
    host: host,
    identifier: "MyAWSClient",
    eventLoopGroupProvider: .createNew,
    configuration: .init(useSSL: true, useWebSockets: true, webSocketURLPath: requestUri)
)
```
You can find out more about connecting to AWS brokers [here](https://docs.aws.amazon.com/iot/latest/developerguide/protocols.html)

## MQTT Version 5.0

Version 2.0 of MQTTNIO added support for MQTT v5.0. To create a client that will connect to a v5 MQTT broker you need to set the version in the configuration as follows

```swift
let client = MQTTClient(
    host: host,
    identifier: "MyAWSClient",
    eventLoopGroupProvider: .createNew,
    configuration: .init(version: .v5_0)
)
```

You can then use the same functions available to the v3.1.1 client but there are also v5.0 specific versions of `connect`, `publish`, `subscribe`, `unsubscribe` and `disconnect`. These can be accessed via the variable `MQTTClient.v5`. The v5.0 functions add support for MQTT properties in both function parameters and return types and the additional subscription parameters. For example here is a `publish` call adding the `contentType` property.

```swift
let futureResponse = client.v5.publish(
    to: "JSONTest", 
    payload: payload, 
    qos: .atLeastOnce, 
    properties: [.contentType("application/json")]
)
```

Whoever subscribes to the "JSONTest" topic with a v5.0 client will also receive the `.contentType` property along with the payload.

## Documentation

You can find reference documentation for MQTTNIO [here](https://adam-fowler.github.io/mqtt-nio/). There is also a sample demonstrating using MQTTNIO within an iOS app found [here](https://github.com/adam-fowler/EmCuTeeTee)
