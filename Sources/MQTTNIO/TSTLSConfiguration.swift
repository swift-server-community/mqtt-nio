#if canImport(Network)

import Foundation
import Network
#if canImport(NIOSSL)
import NIOSSL
#endif

/// TLS Version enumeration
public enum TSTLSVersion {
    case tlsV10
    case tlsV11
    case tlsV12
    case tlsV13

    /// return `SSLProtocol` for iOS12 api
    var sslProtocol: SSLProtocol {
        switch self {
        case .tlsV10:
            return .tlsProtocol1
        case .tlsV11:
            return .tlsProtocol11
        case .tlsV12:
            return .tlsProtocol12
        case .tlsV13:
            return .tlsProtocol13
        }
    }

    /// return `tls_protocol_version_t` for iOS13 and later apis
    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    var tlsProtocolVersion: tls_protocol_version_t {
        switch self {
        case .tlsV10:
            return .TLSv10
        case .tlsV11:
            return .TLSv11
        case .tlsV12:
            return .TLSv12
        case .tlsV13:
            return .TLSv13
        }
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension tls_protocol_version_t {
    var tsTLSVersion: TSTLSVersion {
        switch self {
        case .TLSv10:
            return .tlsV10
        case .TLSv11:
            return .tlsV11
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
public enum TSCertificateVerification {
    /// All certificate verification disabled.
    case none

    /// Certificates will be validated against the trust store and checked
    /// against the hostname of the service we are contacting.
    case fullVerification
}

/// TLS configuration for NIO Transport Services
public struct TSTLSConfiguration {
    /// Error loading TLS files
    public enum Error: Swift.Error {
        case invalidData
    }

    /// Struct defining an array of certificates
    public struct Certificates {
        let certificates: [SecCertificate]

        /// Create certificate array from already loaded SecCertificate array
        public static func certificates(_ secCertificates: [SecCertificate]) -> Self { .init(certificates: secCertificates) }

        #if canImport(NIOSSL)
        /// Create certificate array from PEM file
        public static func pem(_ filename: String) throws -> Self {
            let certificates = try NIOSSLCertificate.fromPEMFile(filename)
            let secCertificates = try certificates.map { certificate -> SecCertificate in
                guard let certificate = SecCertificateCreateWithData(nil, Data(try certificate.toDERBytes()) as CFData) else { throw TSTLSConfiguration.Error.invalidData }
                return certificate
            }
            return .init(certificates: secCertificates)
        }
        #endif

        /// Create certificate array from DER file
        public static func der(_ filename: String) throws -> Self {
            let certificateData = try Data(contentsOf: URL(fileURLWithPath: filename))
            guard let secCertificate = SecCertificateCreateWithData(nil, certificateData as CFData) else { throw TSTLSConfiguration.Error.invalidData }
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
            guard SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems) == errSecSuccess else { throw TSTLSConfiguration.Error.invalidData }
            let items = rawItems! as! [[String: Any]]
            guard let firstItem = items.first,
                  let secIdentity = firstItem[kSecImportItemIdentity as String] as! SecIdentity?
            else {
                throw TSTLSConfiguration.Error.invalidData
            }
            return .init(identity: secIdentity)
        }
    }

    /// The minimum TLS version to allow in negotiation. Defaults to tlsv1.
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
        minimumTLSVersion: TSTLSVersion = .tlsV10,
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
        minimumTLSVersion: TSTLSVersion = .tlsV10,
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
    func getNWProtocolTLSOptions() throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        // minimum TLS protocol
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, self.minimumTLSVersion.tlsProtocolVersion)
        } else {
            sec_protocol_options_set_tls_min_version(options.securityProtocolOptions, self.minimumTLSVersion.sslProtocol)
        }

        // maximum TLS protocol
        if let maximumTLSVersion = self.maximumTLSVersion {
            if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, maximumTLSVersion.tlsProtocolVersion)
            } else {
                sec_protocol_options_set_tls_max_version(options.securityProtocolOptions, maximumTLSVersion.sslProtocol)
            }
        }

        if let clientIdentity = self.clientIdentity, let secClientIdentity = sec_identity_create(clientIdentity) {
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, secClientIdentity)
        }

        self.applicationProtocols.forEach {
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, $0)
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
                    if let trustRootCertificates = trustRoots {
                        SecTrustSetAnchorCertificates(trust, trustRootCertificates as CFArray)
                    }
                    if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                        SecTrustEvaluateAsyncWithError(trust, Self.tlsDispatchQueue) { _, result, error in
                            if let error = error {
                                print("Trust failed: \(error.localizedDescription)")
                            }
                            sec_protocol_verify_complete(result)
                        }
                    } else {
                        SecTrustEvaluateAsync(trust, Self.tlsDispatchQueue) { _, result in
                            switch result {
                            case .proceed, .unspecified:
                                sec_protocol_verify_complete(true)
                            default:
                                sec_protocol_verify_complete(false)
                            }
                        }
                    }
                }, Self.tlsDispatchQueue
            )
        }
        return options
    }

    /// Dispatch queue used by Network framework TLS to control certificate verification
    static var tlsDispatchQueue = DispatchQueue(label: "TSTLSConfiguration")
}

/// Deprecated TSTLSConfiguration
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@available(*, deprecated, message: "Use the init using TSTLSVersion")
extension TSTLSConfiguration {
    /// Initialize TSTLSConfiguration
    public init(
        minimumTLSVersion: tls_protocol_version_t,
        maximumTLSVersion: tls_protocol_version_t? = nil,
        trustRoots: Certificates,
        clientIdentity: Identity,
        applicationProtocols: [String] = [],
        certificateVerification: TSCertificateVerification = .fullVerification
    ) {
        self.minimumTLSVersion = minimumTLSVersion.tsTLSVersion
        self.maximumTLSVersion = maximumTLSVersion?.tsTLSVersion
        self.trustRoots = trustRoots.certificates
        self.clientIdentity = clientIdentity.identity
        self.applicationProtocols = applicationProtocols
        self.certificateVerification = certificateVerification
    }

    /// Initialize TSTLSConfiguration
    public init(
        minimumTLSVersion: tls_protocol_version_t,
        maximumTLSVersion: tls_protocol_version_t? = nil,
        trustRoots: [SecCertificate]? = nil,
        clientIdentity: SecIdentity? = nil,
        applicationProtocols: [String] = [],
        certificateVerification: TSCertificateVerification = .fullVerification
    ) {
        self.minimumTLSVersion = minimumTLSVersion.tsTLSVersion
        self.maximumTLSVersion = maximumTLSVersion?.tsTLSVersion
        self.trustRoots = trustRoots
        self.clientIdentity = clientIdentity
        self.applicationProtocols = applicationProtocols
        self.certificateVerification = certificateVerification
    }
}

#endif
