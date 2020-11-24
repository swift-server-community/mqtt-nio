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

Subscribe to a topic and add a publish listener to report publish messages from the broker.
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
let payload = ByteBufferAllocator().buffer(string: "This is the Test payload")
try client.publish(
    to: "my-topics",
    payload: payload,
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

let host = "MY_AWS_IOT_ENDPOINT"
let port = 443
let headers = HTTPHeaders([("host", host)])
let signer = AWSSigner(
    credentials: StaticCredential(accessKeyId: "MYACCESSKEY", secretAccessKey: "MYSECRETKEY"), 
    name: "iotdata", 
    region: "eu-west-1"
)
let signedURL = signer.signURL(
    url: URL(string: "https://\(host):\(port)/mqtt")!, 
    method: .GET, 
    headers: headers, 
    body: .none, 
    expires: .minutes(30)
)
let requestURI = "/mqtt?\(signedURL.query!)"
let client = MQTTClient(
    host: host,
    port: port,
    identifier: "MyAWSClient",
    eventLoopGroupProvider: .createNew,
    configuration: .init(useSSL: true, useWebSockets: true, webSocketURLPath: requestUri)
)
```
You can find out more about connecting to AWS brokers [here](https://docs.aws.amazon.com/iot/latest/developerguide/protocols.html)
