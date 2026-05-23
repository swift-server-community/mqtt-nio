# Connections

Support for TLS, WebSockets, and Unix Domain Sockets.

## TLS

MQTT NIO supports TLS connections.
You can enable this through the ``MQTTConnectionConfiguration/TLS`` provided at initialization.
For example, to connect to the mosquitto test server `test.mosquitto.org` on port 8884 you need to provide their root certificate and your own certificate.
They provide details on the website [https://test.mosquitto.org/](https://test.mosquitto.org/) on how to generate these.

```swift
let rootCertificate = try NIOSSLCertificate.fromPEMBytes([UInt8](mosquittoCertificateText.utf8))
let myCertificate = try NIOSSLCertificate.fromPEMBytes([UInt8](myCertificateText.utf8))
let myPrivateKey = try NIOSSLPrivateKey(bytes: [UInt8](myPrivateKeyText.utf8), format: .pem)
let tlsConfiguration: TLSConfiguration? = TLSConfiguration.forClient(
    trustRoots: .certificates(rootCertificate),
    certificateChain: myCertificate.map { .certificate($0) },
    privateKey: .privateKey(myPrivateKey)
)

try await MQTTConnection.withConnection(
    address: .hostname("test.mosquitto.org", port: 8884),
    configuration: .init(tls: .enable(.niossl(tlsConfiguration))),
    identifier: "My SSL Client",
    logger: Logger(...)
) { connection in
    // Connected to the broker with an encrypted connection
}
```

## WebSockets

MQTT also supports WebSocket connections.
Provide a ``MQTTConnectionConfiguration/WebSocketConfiguration`` when connecting to enable this.

## NIO Transport Services

On macOS and iOS you can use the `NIOTransportServices` library and Apple's `Network.framework` for communication with the MQTT broker.
You have to provide the correct `eventLoopGroup` and ``MQTTConnectionConfiguration/TLS/Configuration`` to choose between `NIOTransportServices` and `NIOSSL`.

Provide a `MultiThreadedEventLoopGroup` and a ``MQTTConnectionConfiguration/TLS/Configuration/niossl(_:)-enum.case`` and the client will use `NIOSSL`.
Provide a `NIOTSEventLoopGroup` or ``MQTTConnectionConfiguration/TLS/Configuration/ts(_:)-enum.case`` and the client will use `NIOTransportServices`.
If you provide a `MultiThreadedEventLoopGroup` and a ``MQTTConnectionConfiguration/TLS/Configuration/ts(_:)-enum.case`` then the client will throw an error.

If you are running on iOS you should always choose `NIOTransportServices`.

## Unix Domain Sockets

MQTT NIO can connect to a local MQTT broker via a Unix Domain Socket.

```swift
try await MQTTConnection.withConnection(
    address: .unixDomainSocket(path: "/path/to/broker.socket"),
    identifier: "My UDS Client",
    logger: Logger(...)
) { connection in
    // Connected to the broker via a Unix Domain Socket
}
```

Note that mosquitto supports listening on a Unix domain socket.
This can be enabled by adding a `listener` option to the mosquitto config.

```
listener 0 /path/to/broker.socket
```
