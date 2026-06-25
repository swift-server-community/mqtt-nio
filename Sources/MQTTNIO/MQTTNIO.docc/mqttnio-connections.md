# Connections

Support for different transport protocols, socket types, and encrypted connections.

## Overview

In MQTT NIO, you establish a connection to the MQTT broker using one of the various `withConnection` methods available on ``MQTTConnection``. These methods provide a closure where you can perform operations using the connection.
When the closure returns, the connection will be closed.
`CONNECT` and `DISCONNECT` packets are sent automatically, respectively before and after the closure is executed.
`DISCONNECT` is sent even if the closure throws an error.

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

If you establish a MQTT v5.0 connection (see <doc:mqttnio-v5>), you can define ``MQTTProperties`` to be sent with the `CONNECT` and `DISCONNECT` packets in the ``MQTTConnectionConfiguration/versionConfiguration``.

You can wait for the connection to be closed, either by the client (by returning from the closure, calling ``MQTTConnection/close()`` or throwing an error) or by the server, with the ``MQTTConnection/waitOnClose()`` method.

The available variants of `withConnection` are:
- ``MQTTConnection/withConnection(address:configuration:identifier:eventLoop:logger:operation:)-(_,_,_,_,_,(MQTTConnection)->Value)``
    - Connect to the MQTT server with a clean session (clean start in MQTT v5.0) using the provided identifier for the session; you cannot resume a previous session.
- ``MQTTConnection/withConnection(address:configuration:session:eventLoop:logger:operation:)-(_,_,_,_,_,(MQTTConnection,Bool)->Value)``
    - Connect to the MQTT server using the provided session; see <doc:mqttnio-sessions> for more details. The closure also receives a `Bool` indicating whether the server had a previous session for the provided session client ID and whether that session has been resumed.

With the method `withConnection`, you can open various types of connections to MQTT brokers by configuring the following options:

- <doc:mqttnio-connections#Transport-protocol> to use, such as TCP (default) or WebSockets
- Unencrypted (by default) or encrypted connections via <doc:mqttnio-connections#TLS>
- Connections using Apple's `Network.framework` for iOS via <doc:mqttnio-connections#NIO-Transport-Services>
- POSIX sockets or <doc:mqttnio-connections#Unix-Domain-Sockets>

### Transport protocol

MQTT NIO supports different transport protocols for connecting to the MQTT broker, such as:

- TCP sockets (by default)
- WebSockets connections (see ``MQTTConnectionConfiguration/Transport/WebSocketConfiguration``)

The transport protocol can be configured through the ``MQTTConnectionConfiguration/transport`` property.

```swift
try await MQTTConnection.withConnection(
    address: .hostname("test.mosquitto.org", port: 8080),
    configuration: .init(transport: .webSocket(.init(...))),
    identifier: "My WebSocket Client",
    logger: Logger(...)
) { connection in
    // Connected to the broker via WebSockets
}
```

### TLS

MQTT NIO supports TLS connections.
You can enable this through the ``MQTTConnectionConfiguration/Transport/TLS`` provided at initialization.
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
    configuration: .init(transport: .tcp(tls: .enable(.niossl(tlsConfiguration)))),
    identifier: "My SSL Client",
    logger: Logger(...)
) { connection in
    // Connected to the broker with an encrypted connection
}
```

### NIO Transport Services

On macOS and iOS you can use the `NIOTransportServices` library and Apple's `Network.framework` for communication with the MQTT broker.
You have to provide the correct `eventLoopGroup` and ``MQTTConnectionConfiguration/Transport/TLS/Configuration`` to choose between `NIOTransportServices` and `NIOSSL`.

Provide a `MultiThreadedEventLoopGroup` and a ``MQTTConnectionConfiguration/Transport/TLS/Configuration/niossl(_:)-enum.case`` and the client will use `NIOSSL`.
Provide a `NIOTSEventLoopGroup` or ``MQTTConnectionConfiguration/Transport/TLS/Configuration/ts(_:)-enum.case`` and the client will use `NIOTransportServices`.
If you provide a `MultiThreadedEventLoopGroup` and a ``MQTTConnectionConfiguration/Transport/TLS/Configuration/ts(_:)-enum.case`` then the client will throw an error.

If you are running on iOS you should always choose `NIOTransportServices`.

### Unix Domain Sockets

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
