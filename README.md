# MQTT NIO

[![sswg:sandbox|94x20](https://img.shields.io/badge/sswg-sandbox-lightgrey.svg)](https://github.com/swift-server/sswg/blob/master/process/incubation.md#sandbox-level)
[<img src="https://img.shields.io/badge/swift-5.7-brightgreen.svg" alt="Swift 5.7" />](https://swift.org)
[<img src="https://github.com/adam-fowler/mqtt-nio/workflows/CI/badge.svg" />](https://github.com/adam-fowler/mqtt-nio/workflows/CI/badge.svg)

A Swift NIO based MQTT v3.1.1 and v5.0 client.

MQTT (Message Queuing Telemetry Transport) is a lightweight messaging protocol that was developed by IBM and first released in 1999. It uses the pub/sub pattern and translates messages between devices, servers, and applications. It is commonly used in Internet of things (IoT) technologies.

MQTTNIO is a Swift NIO based implementation of a MQTT client. It supports
- MQTT versions 3.1.1 and 5.0.
- Unencrypted and encrypted (via TLS) connections
- WebSocket connections
- Posix sockets
- Apple's Network framework via [NIOTransportServices](https://github.com/apple/swift-nio-transport-services) (required for iOS).

You can find documentation for MQTTNIO
[here](https://swift-server-community.github.io/mqtt-nio/documentation/mqttnio/). There is also a sample demonstrating the use MQTTNIO in an iOS app found [here](https://github.com/adam-fowler/EmCuTeeTee)
