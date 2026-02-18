//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2022 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)

@preconcurrency public import Security

import Foundation
import Logging
import Network
#if os(macOS) || os(Linux) || os(Android)
import NIOSSL
#endif

/// TLS Version enumeration
public enum TSTLSVersion: Sendable {
    case tlsV12
    case tlsV13

    var tlsProtocolVersion: tls_protocol_version_t {
        switch self {
        case .tlsV12:
            return .TLSv12
        case .tlsV13:
            return .TLSv13
        }
    }
}

extension tls_protocol_version_t {
    var tsTLSVersion: TSTLSVersion {
        switch self {
        case .TLSv12:
            return .tlsV12
        case .TLSv13:
            return .tlsV13
        default:
            preconditionFailure("Invalid TLS version")
        }
    }
}

/// Certificate verification modes.
public enum TSCertificateVerification: Sendable {
    /// All certificate verification disabled.
    case none

    /// Certificates will be validated against the trust store and checked
    /// against the hostname of the service we are contacting.
    case fullVerification
}

/// TLS configuration for NIO Transport Services
public struct TSTLSConfiguration: Sendable {
    /// Error loading TLS files
    public enum Error: Swift.Error {
        case invalidData
    }

    /// Struct defining an array of certificates
    public struct Certificates {
        let certificates: [SecCertificate]

        /// Create certificate array from already loaded SecCertificate array
        public static func certificates(_ secCertificates: [SecCertificate]) -> Self { .init(certificates: secCertificates) }

        #if os(macOS) || os(Linux) || os(Android)
        /// Create certificate array from PEM file
        public static func pem(_ filename: String) throws -> Self {
            let certificates = try NIOSSLCertificate.fromPEMFile(filename)
            let secCertificates = try certificates.map { certificate -> SecCertificate in
                guard let certificate = try SecCertificateCreateWithData(nil, Data(certificate.toDERBytes()) as CFData) else {
                    throw TSTLSConfiguration.Error.invalidData
                }
                return certificate
            }
            return .init(certificates: secCertificates)
        }
        #endif

        /// Create certificate array from DER file
        public static func der(_ filename: String) throws -> Self {
            let certificateData = try Data(contentsOf: URL(fileURLWithPath: filename))
            guard let secCertificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
                throw TSTLSConfiguration.Error.invalidData
            }
            return .init(certificates: [secCertificate])
        }
    }

    /// Struct defining identity
    public struct Identity {
        let identity: SecIdentity

        /// Create Identity from already loaded SecIdentity
        public static func secIdentity(_ secIdentity: SecIdentity) -> Self { .init(identity: secIdentity) }

        /// Create Identity from p12 file
        public static func p12(filename: String, password: String) throws -> Self {
            let data = try Data(contentsOf: URL(fileURLWithPath: filename))
            let options: [String: String] = [kSecImportExportPassphrase as String: password]
            var rawItems: CFArray?
            guard SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems) == errSecSuccess else {
                throw TSTLSConfiguration.Error.invalidData
            }
            let items = rawItems! as! [[String: Any]]
            guard let firstItem = items.first,
                let secIdentity = firstItem[kSecImportItemIdentity as String] as! SecIdentity?
            else {
                throw TSTLSConfiguration.Error.invalidData
            }
            return .init(identity: secIdentity)
        }
    }

    /// The minimum TLS version to allow in negotiation. Defaults to tlsv12.
    public var minimumTLSVersion: TSTLSVersion

    /// The maximum TLS version to allow in negotiation. If nil, there is no upper limit. Defaults to nil.
    public var maximumTLSVersion: TSTLSVersion?

    /// The trust roots to use to validate certificates. This only needs to be provided if you intend to validate
    /// certificates.
    public var trustRoots: [SecCertificate]?

    /// The identity associated with the leaf certificate.
    public var clientIdentity: SecIdentity?

    /// The application protocols to use in the connection.
    public var applicationProtocols: [String]

    /// Whether to verify remote certificates.
    public var certificateVerification: TSCertificateVerification

    /// Initialize TSTLSConfiguration
    /// - Parameters:
    ///   - minimumTLSVersion: minimum version of TLS supported
    ///   - maximumTLSVersion: maximum version of TLS supported
    ///   - trustRoots: The trust roots to use to validate certificates
    ///   - clientIdentity: Client identity
    ///   - applicationProtocols: The application protocols to use in the connection
    ///   - certificateVerification: Should certificates be verified
    public init(
        minimumTLSVersion: TSTLSVersion = .tlsV12,
        maximumTLSVersion: TSTLSVersion? = nil,
        trustRoots: [SecCertificate]? = nil,
        clientIdentity: SecIdentity? = nil,
        applicationProtocols: [String] = [],
        certificateVerification: TSCertificateVerification = .fullVerification
    ) {
        self.minimumTLSVersion = minimumTLSVersion
        self.maximumTLSVersion = maximumTLSVersion
        self.trustRoots = trustRoots
        self.clientIdentity = clientIdentity
        self.applicationProtocols = applicationProtocols
        self.certificateVerification = certificateVerification
    }

    /// Initialize TSTLSConfiguration
    /// - Parameters:
    ///   - minimumTLSVersion: minimum version of TLS supported
    ///   - maximumTLSVersion: maximum version of TLS supported
    ///   - trustRoots: The trust roots to use to validate certificates
    ///   - clientIdentity: Client identity
    ///   - applicationProtocols: The application protocols to use in the connection
    ///   - certificateVerification: Should certificates be verified
    public init(
        minimumTLSVersion: TSTLSVersion = .tlsV12,
        maximumTLSVersion: TSTLSVersion? = nil,
        trustRoots: Certificates,
        clientIdentity: Identity,
        applicationProtocols: [String] = [],
        certificateVerification: TSCertificateVerification = .fullVerification
    ) {
        self.minimumTLSVersion = minimumTLSVersion
        self.maximumTLSVersion = maximumTLSVersion
        self.trustRoots = trustRoots.certificates
        self.clientIdentity = clientIdentity.identity
        self.applicationProtocols = applicationProtocols
        self.certificateVerification = certificateVerification
    }
}

extension TSTLSConfiguration {
    func getNWProtocolTLSOptions(logger: Logger) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        // minimum TLS protocol
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, self.minimumTLSVersion.tlsProtocolVersion)

        // maximum TLS protocol
        if let maximumTLSVersion = self.maximumTLSVersion {
            sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, maximumTLSVersion.tlsProtocolVersion)
        }

        if let clientIdentity = self.clientIdentity, let secClientIdentity = sec_identity_create(clientIdentity) {
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, secClientIdentity)
        }

        for applicationProtocol in self.applicationProtocols {
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, applicationProtocol)
        }

        if self.certificateVerification != .fullVerification || self.trustRoots != nil {
            // add verify block to control certificate verification
            sec_protocol_options_set_verify_block(
                options.securityProtocolOptions,
                { _, sec_trust, sec_protocol_verify_complete in
                    guard self.certificateVerification != .none else {
                        sec_protocol_verify_complete(true)
                        return
                    }

                    let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                    if let trustRootCertificates = self.trustRoots {
                        SecTrustSetAnchorCertificates(trust, trustRootCertificates as CFArray)
                    }
                    SecTrustEvaluateAsyncWithError(trust, Self.tlsDispatchQueue) { _, result, error in
                        if let error {
                            logger.error("Trust failed: \(error.localizedDescription)")
                        }
                        sec_protocol_verify_complete(result)
                    }
                },
                Self.tlsDispatchQueue
            )
        }
        return options
    }

    /// Dispatch queue used by Network framework TLS to control certificate verification
    static let tlsDispatchQueue = DispatchQueue(label: "TSTLSConfiguration")
}

#endif
