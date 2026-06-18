//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import Configuration
import HTTPTypes
import NIOCore
import Testing

@testable import MQTTNIO

#if os(macOS) || os(Linux) || os(Android)
import NIOSSL
#endif

@Suite("Configuration Tests")
struct ConfigurationTests {
    @Test("MQTTConnectionConfiguration+ConfigReader")
    func connectionConfiguration() throws {
        let configReader = ConfigReader(
            provider: InMemoryProvider(
                values: [
                    "version": "3",
                    "will.topicName": "test/topic",
                    "will.payload": .init(.bytes([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x2C, 0x20, 0x57, 0x6F, 0x72, 0x6C, 0x64, 0x21]), isSecret: false),
                    "will.qos": 2,
                    "will.retain": true,
                    "keepAliveInterval": 30,
                    "ping": 10,
                    "connectTimeout": 20,
                    "timeout": 20,
                    "userName": "mqtt_user",
                    "password": .init(.string("mqtt_password"), isSecret: true),
                    "tls.config": "niossl",
                    "tls.certificateChain": .init(stringLiteral: serverCertificateData),
                    "tls.privateKey": .init(stringLiteral: serverPrivateKeyData),
                    "tls.trustRoots": .init(stringLiteral: caCertificateData),
                    "tls.serverName": "example.com",
                    "webSocket.urlPath": "/test",
                    "webSocket.maxFrameSize": 21,
                    "webSocket.initialRequestHeaders": .init(
                        .stringArray([
                            "X-Custom-Header: CustomValue",
                            "X-Another-Header: AnotherValue",
                        ]),
                        isSecret: false
                    ),
                ]
            )
        )

        let config = MQTTConnectionConfiguration(config: configReader)
        guard case .v3_1_1(let willMessage) = config.versionConfiguration, let willMessage else {
            Issue.record("Expected MQTT version to be 3.1.1")
            return
        }
        #expect(willMessage.topicName == "test/topic")
        #expect(willMessage.payload == ByteBuffer(string: "Hello, World!"))
        #expect(willMessage.qos == .exactlyOnce)
        #expect(willMessage.retain)
        #expect(config.keepAliveInterval == .seconds(30))
        guard case .pingInterval(let interval) = config.pingConfiguration.base else {
            Issue.record("Expected ping configuration to be a ping interval")
            return
        }
        #expect(interval == .seconds(10))
        #expect(config.connectTimeout == .seconds(20))
        #expect(config.timeout == .seconds(20))
        #expect(config.userName == "mqtt_user")
        #expect(config.password == "mqtt_password")
        let serverTLSConfiguration = try getServerTLSConfiguration()
        guard case .enable(let tlsConfig, let tlsServerName) = config.tls.base,
            case .niossl(let tlsConfiguration) = tlsConfig,
            tlsServerName == "example.com"
        else {
            Issue.record("Expected TLS to be enabled with NIOSSL configuration")
            return
        }
        #expect(tlsConfiguration.certificateChain == serverTLSConfiguration.certificateChain)
        #expect(tlsConfiguration.privateKey == serverTLSConfiguration.privateKey)
        #expect(tlsConfiguration.trustRoots == serverTLSConfiguration.trustRoots)
        #expect(config.webSocketConfiguration?.urlPath == "/test")
        #expect(config.webSocketConfiguration?.maxFrameSize == 21)
        #expect(config.webSocketConfiguration?.initialRequestHeaders.count == 2)
    }

    @Test("MQTTQoS+ExpressibleByConfigInt", arguments: MQTTQoS.allCases)
    func qosConfigInt(qos: MQTTQoS) {
        #expect(MQTTQoS(configInt: Int(qos.rawValue)) == qos)
        #expect(qos.configInt == qos.rawValue)
    }

    @Test("Will Message")
    func willMessage() throws {
        let configReader = ConfigReader(
            provider: InMemoryProvider(
                values: [
                    "topicName": "test/topic",
                    "payload": .init(.bytes([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x2C, 0x20, 0x57, 0x6F, 0x72, 0x6C, 0x64, 0x21]), isSecret: false),
                    "qos": 2,
                    "retain": true,
                ]
            )
        )

        let v3Will = try MQTTConnectionConfiguration.VersionConfiguration.WillMessageV311(config: configReader)
        #expect(v3Will.topicName == "test/topic")
        #expect(v3Will.payload == ByteBuffer(string: "Hello, World!"))
        #expect(v3Will.qos == .exactlyOnce)
        #expect(v3Will.retain)

        let v5Will = try MQTTConnectionConfiguration.VersionConfiguration.WillMessageV5(config: configReader)
        #expect(v5Will.topicName == "test/topic")
        #expect(v5Will.payload == ByteBuffer(string: "Hello, World!"))
        #expect(v5Will.qos == .exactlyOnce)
        #expect(v5Will.retain)
    }

    @Test("Ping Configuration", arguments: [ConfigValue(.string("disable"), isSecret: false), "useServerKeepAlive", 21, "invalid"])
    func pingConfiguration(value: ConfigValue) {
        let configReader = ConfigReader(provider: InMemoryProvider(values: ["ping": value]))
        let pingConfiguration = MQTTConnectionConfiguration.PingConfiguration(config: configReader)
        switch (value.content, pingConfiguration.base) {
        case (.int(let seconds), .pingInterval(let duration)):
            #expect(duration == .seconds(seconds))
        case (.string(let string), .disable):
            #expect(string == "disable")
        case (.string, .useServerKeepAlive):
            // With invalid strings it defaults to `useServerKeepAlive`
            break
        default:
            Issue.record("Invalid combination of ConfigValue and PingConfiguration")
        }
    }

    @Test("TLS with NIOSSL")
    func tlsNIOSSL() throws {
        func getServerTLSConfiguration() throws -> TLSConfiguration {
            let caCertificate = try NIOSSLCertificate(bytes: [UInt8](caCertificateData.utf8), format: .pem)
            let certificate = try NIOSSLCertificate(bytes: [UInt8](serverCertificateData.utf8), format: .pem)
            let privateKey = try NIOSSLPrivateKey(bytes: [UInt8](serverPrivateKeyData.utf8), format: .pem)
            var tlsConfig = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(certificate)],
                privateKey: .privateKey(privateKey)
            )
            tlsConfig.trustRoots = .certificates([caCertificate])
            return tlsConfig
        }

        let configReader = ConfigReader(
            providers: [
                InMemoryProvider(values: [
                    "config": "niossl",
                    "certificateChain": .init(stringLiteral: serverCertificateData),
                    "privateKey": .init(stringLiteral: serverPrivateKeyData),
                    "trustRoots": .init(stringLiteral: caCertificateData),
                    "serverName": "example.com",
                ])
            ]
        )

        let tls = try MQTTConnectionConfiguration.TLS(config: configReader)
        let serverTLSConfiguration = try getServerTLSConfiguration()
        guard case .enable(let config, let tlsServerName) = tls.base,
            case .niossl(let tlsConfiguration) = config,
            tlsServerName == "example.com"
        else {
            Issue.record("Expected TLS to be enabled with NIOSSL configuration")
            return
        }
        #expect(tlsConfiguration.certificateChain == serverTLSConfiguration.certificateChain)
        #expect(tlsConfiguration.privateKey == serverTLSConfiguration.privateKey)
        #expect(tlsConfiguration.trustRoots == serverTLSConfiguration.trustRoots)
    }

    @Test("ConfigHTTPField")
    func configHTTPField() {
        let configReader = ConfigReader(
            provider: InMemoryProvider(
                values: [
                    "initialRequestHeaders": ConfigValue(
                        .stringArray([
                            "X-Custom-Header: CustomValue",
                            "X-Another-Header: AnotherValue",
                        ]),
                        isSecret: false
                    )
                ]
            )
        )
        let initialRequestHeaders = configReader.stringArray(forKey: "initialRequestHeaders", as: ConfigHTTPField.self)
        #expect(initialRequestHeaders?.count == 2)
        #expect(initialRequestHeaders?[0].name == HTTPField.Name("X-Custom-Header"))
        #expect(initialRequestHeaders?[0].value == "CustomValue")
    }

    let caCertificateData =
        """
        -----BEGIN CERTIFICATE-----
        MIIDZDCCAkwCCQD0NlEDBAHjqjANBgkqhkiG9w0BAQsFADB0MQswCQYDVQQGEwJV
        SzESMBAGA1UECAwJRWRpbmJ1cmdoMRIwEAYDVQQHDAlFZGluYnVyZ2gxFDASBgNV
        BAoMC0h1bW1pbmdiaXJkMQswCQYDVQQLDAJDQTEaMBgGA1UEAwwRaHVtbWluZ2Jp
        cmQuY29kZXMwHhcNMjUwMTI3MDg1NTM5WhcNMzAwMTI2MDg1NTM5WjB0MQswCQYD
        VQQGEwJVSzESMBAGA1UECAwJRWRpbmJ1cmdoMRIwEAYDVQQHDAlFZGluYnVyZ2gx
        FDASBgNVBAoMC0h1bW1pbmdiaXJkMQswCQYDVQQLDAJDQTEaMBgGA1UEAwwRaHVt
        bWluZ2JpcmQuY29kZXMwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDI
        uzaSit8quh4TvdVPAT0QqH6gYluhsGgVjU+w55E+Yx698Os44IE5pudYiI/ufo2a
        Ttc14uNqx15/irz6xWHYlPrAoBaH6Q14gs4Zw7ZPh1ngx8/JqzEwJ523a+CPCc73
        Q9VdwjfN09C9DpkRpym6Kuoo3+h9/StgTmf1izf5fyNKtr1sWlRAps1H1AZpFP0B
        K/qxCXC/oOfRzjeaQ+vw/vdEA4w998ePX0CaCkDOa/aQKZEFsjJ5w3xEhRipgzPw
        6pMdNhvrL/MzSwJvdt9Y2EjXzhlqj6H+JU8tCseUf8u1ij0Mv6ux+oBCBmRUs2vm
        CROEulZKLPAubjGUqi89AgMBAAEwDQYJKoZIhvcNAQELBQADggEBALkJRZaH6GtK
        fyFP3PnTdu319XShP6feBz1v0XlTGSJYA+ufE8fruoJoB+a/AonB0BqNnt5UUBL3
        fz3z3GEcEHiu9h83bq7vRnKYTyflqKn7YMtQegRMROLFmtPyPOvZTWt0OCKR2OwP
        OFAdj8yblVy/rYetoOBGjvX2H9UuAn9w+3fDbWExPD4BEyeEoZnMh9xUgXau8GMu
        bhQmaGE4lDGL8XU6a2M+XkI+YdwKQs+HviT2Cmv3QwCfBZuMnOD4U4+tcnYlz3q2
        O67quuvn46uQFcgxaZwuzQ2vVBzSWSj5JA2GDej4UQipGFLkoLtXdckiJI0LFkHr
        jGFTl9ts7yg=
        -----END CERTIFICATE-----
        """

    let serverCertificateData =
        """
        -----BEGIN CERTIFICATE-----
        MIIDuzCCAqOgAwIBAgIJAIKDFx1aQwi8MA0GCSqGSIb3DQEBCwUAMHQxCzAJBgNV
        BAYTAlVLMRIwEAYDVQQIDAlFZGluYnVyZ2gxEjAQBgNVBAcMCUVkaW5idXJnaDEU
        MBIGA1UECgwLSHVtbWluZ2JpcmQxCzAJBgNVBAsMAkNBMRowGAYDVQQDDBFodW1t
        aW5nYmlyZC5jb2RlczAeFw0yNTAxMjcwODU1MzlaFw0zMDAxMjYwODU1MzlaMHgx
        CzAJBgNVBAYTAlVLMRIwEAYDVQQIDAlFZGluYnVyZ2gxEjAQBgNVBAcMCUVkaW5i
        dXJnaDEUMBIGA1UECgwLSHVtbWluZ2JpcmQxDzANBgNVBAsMBlNlcnZlcjEaMBgG
        A1UEAwwRaHVtbWluZ2JpcmQuY29kZXMwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw
        ggEKAoIBAQChAarpHioO8b3MVwPFOPq+1YEFAeLZxOXnPRPof+qT0apRsYsDpQQu
        hPWF6fvW1HcpkAGCb9e935Sx172FqHCfAMKI7JaNPn1+wZNAHd0d4tho8bgONdkf
        s9XQZcVLRbc4Gym14sIcfKEOsPUDJISXYQ2nNprSgBVb709SO/JxpTTugJAeAqyW
        bln4db98LpaXNoakaL9py1yUgkosD2GLJl8maueR7Aimf40MmOaVZvvTce11raVg
        iUZtz3CkOdzFLFdQSP9CczkM7Bon8+RyXgM7BUpF9bXu8dL7kRkSu5E9S6bR8CR5
        lwBtoXzw6187GBThVc0R9hiYM/e6cjIHAgMBAAGjTDBKMAsGA1UdDwQEAwIFoDAd
        BgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwHAYDVR0RBBUwE4IRaHVtbWlu
        Z2JpcmQuY29kZXMwDQYJKoZIhvcNAQELBQADggEBACGATnuWnyBK97EeiI+c+8QK
        Aqr9DCt2NQDrC/RIjPgTMfQ3GFWB+8O2rdr2EwGSVj7ovdw8T8LNvccg8P8B6CFL
        E2oPftWghIg5o23BnO5IovpbQKeDien9oUwiEloYvVc6k221Ah3iC/mW9VYJeFYd
        29fhSypXao0mWnzl8CKeB665XX9Q64wRL6tzoiFzRVJCCfF3cQytpI2FzuWmkJfJ
        ECf8CLOYAK3Ko218h14e02J3T1ZMbXJa8mSAG32HqRpABxxfBZdi88XsA6h8qKT/
        dTF/dRScAjFXwxAwFIUVCqct+IfGokUHvkij73bCIJNZL79kRZh2MrndM/OOkNw=
        -----END CERTIFICATE-----
        """

    let serverPrivateKeyData =
        """
        -----BEGIN PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQChAarpHioO8b3M
        VwPFOPq+1YEFAeLZxOXnPRPof+qT0apRsYsDpQQuhPWF6fvW1HcpkAGCb9e935Sx
        172FqHCfAMKI7JaNPn1+wZNAHd0d4tho8bgONdkfs9XQZcVLRbc4Gym14sIcfKEO
        sPUDJISXYQ2nNprSgBVb709SO/JxpTTugJAeAqyWbln4db98LpaXNoakaL9py1yU
        gkosD2GLJl8maueR7Aimf40MmOaVZvvTce11raVgiUZtz3CkOdzFLFdQSP9CczkM
        7Bon8+RyXgM7BUpF9bXu8dL7kRkSu5E9S6bR8CR5lwBtoXzw6187GBThVc0R9hiY
        M/e6cjIHAgMBAAECggEABBDdtwta9oumRl3AK5/XvS/5FR5KE0PEpoVFVm68hsUZ
        rvxzzUDCjUYwSRRylqdA5xzK3PdkFFhsEd2n3JM3XNyRDRIkbyav1p6e0FSwu8t5
        uZS5GCrF8+X/tUaMp+z3xoPxFrXGPx/qlUtktJKcgpIh3SIk4MH5SBwP/byjz7jZ
        DfqDIbVG07PCwXe0LEmd8AEGT6vOXULG5SBkTwz/7BSdzgKvDWIgCDjIdDAahdhW
        LSIn9FT1xDeCeOimFwA4ZdM96ZnFlLJwP4WBmqUWgKfsXBc+Oa8ZDlmsDEkhmzCy
        mBNDOxJVgJ5YOURTpTRPeMoDBxkQbQ1V5MRJng9q0QKBgQDRrVORq74LqtgMOb9o
        Ff2T3z/RE1PzW8jlXnrK3lBcW4Ivt4N4xmFCSWlW7PBTtkCGJfSMZA1MNkK1sBl7
        L2FWqh6KymTdBCedsGFrwNiaVXmJWtUimxS3OAFr4/mJWYIIwz43wzXsxhmSOQD+
        T3/kquDCtYq1cvPHtOdTgu/26QKBgQDEk7BNdIZw0TM8YprdC+OiaO05juXEnp2+
        ObKCVDH0KJjpQ9OfqhppMOBG/RP34zGX8c7iJ0uRIgjlIhTHkeDQp974ei8geCTK
        PI90/fhO8pkkpLJZVPreAdj7502jyFYuy79FjQQRMUVOF3YgCYc3kf9aqWGsGT7O
        KkVP3GUrbwKBgFEC37vzmBzX6Fto4GwtuuisI/L6vb/T4Z3FUDobhP76GCWpiLFc
        LG25AWslZoFhdDKgbYjki0K74DBklqPCnaAnYF+NbUT7evbxE+LXApk2lxubraeO
        NYXIrLvrvBj2LUiHbv2KfcY6j9ywC5M2UhqebvKrw6jxfgDWA15/w4kpAoGAK682
        asAOcFvNKwouqBjQSXNP5I6g+QTWwUNJLDVRtJShBpWQHddLbzzxWlU7bscKal3O
        P+vDm0kY+PKN85uzfisQHd/pQSnx4w96QeF+oOzAo6gGClwcM+HtOm24j0EiBdw5
        cVdZJAjzAdus4Im9htfnC1rA3eHuVxqFtK2hvfkCgYEAttVDzfbXDWo4X4g5ZvON
        7ZAldvxQuHhb5JDPwfWR3H/W99tUma5T8e4UhSOU+7dng3xE+LK2aLJXZN6H4VsR
        GeLymDyXs3JLtJyO4JvRp6C+acALua/pyLfeJj+Mk+A+76bmAftqcJ2e7rzp/EgH
        7VbyN0IbfqD+MmEjFat0hRw=
        -----END PRIVATE KEY-----
        """

    func getServerTLSConfiguration() throws -> TLSConfiguration {
        let caCertificate = try NIOSSLCertificate(bytes: [UInt8](caCertificateData.utf8), format: .pem)
        let certificate = try NIOSSLCertificate(bytes: [UInt8](serverCertificateData.utf8), format: .pem)
        let privateKey = try NIOSSLPrivateKey(bytes: [UInt8](serverPrivateKeyData.utf8), format: .pem)
        var tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(privateKey)
        )
        tlsConfig.trustRoots = .certificates([caCertificate])
        return tlsConfig
    }
}
