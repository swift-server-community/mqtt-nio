# Connections

Support for TLS and WebSockets.

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

MQTT also supports Web Socket connections. Provide a `WebSocketConfiguration` when initializing `MQTTClient.Configuration` to enable this.

## NIO Transport Services

On macOS and iOS you can use the NIO Transport Services library (NIOTS) and Apple's `Network.framework` for communication with the MQTT broker. If you don't provide an `eventLoopGroup` or a `TLSConfigurationType` then this is the default for both platforms. If you do provide either of these then the library will base it's decision on whether to use NIOTS or NIOSSL on what you provide. Provide a `MultiThreadedEventLoopGroup` or `NIOSSL.TLSConfiguration` and the client will use NIOSSL. Provide a `NIOTSEventLoopGroup` or `TSTLSConfiguration` and the client will use NIOTS. If you provide a `MultiThreadedEventLoopGroup` and a `TSTLSConfiguration` then the client will throw an error. If you are running on iOS you should always choose NIOTS.
