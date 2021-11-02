#if canImport(Network)

import Foundation
import Network
#if canImport(NIOSSL)
import NIOSSL
#endif

extension tls_protocol_version_t {
    var sslProtocol: SSLProtocol {
        switch self {
        case .TLSv10:
            return .tlsProtocol1
        case .TLSv11:
            return .tlsProtocol11
        case .TLSv12:
            return .tlsProtocol12
        case .TLSv13:
            return .tlsProtocol13
        case .DTLSv10:
            return .dtlsProtocol1
        case .DTLSv12:
            return .dtlsProtocol12
        @unknown default:
            return .tlsProtocol1
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
    enum Error: Swift.Error {
        case invalidData
    }
    /// Struct defining identity
    public struct Certificates {
        let certificates: [SecCertificate]

        public static func certificates(_ secCertificates: [SecCertificate]) -> Self { .init(certificates: secCertificates) }

        #if canImport(NIOSSL)
        public static func pem(_ filename: String) throws -> Self {
            let certificates = try NIOSSLCertificate.fromPEMFile(filename)
            let secCertificates = try certificates.map { certificate -> SecCertificate in
                guard let certificate = SecCertificateCreateWithData(nil, Data(try certificate.toDERBytes()) as CFData) else { throw TSTLSConfiguration.Error.invalidData }
                return certificate
            }
            return .init(certificates: secCertificates)
        }
        #endif

        public static func der(_ filename: String) throws -> Self {
            let certificateData = try Data(contentsOf: URL(fileURLWithPath: filename))
            guard let secCertificate = SecCertificateCreateWithData(nil, certificateData as CFData) else { throw TSTLSConfiguration.Error.invalidData }
            return .init(certificates: [secCertificate])
        }
    }

    /// Struct defining identity
    public struct Identity {
        let identity: SecIdentity

        public static func secIdentity(_ secIdentity: SecIdentity) -> Self { .init(identity: secIdentity) }

        public static func p12(filename: String, password: String) throws -> Self {
            let secIdentity = try Self.loadP12(filename: filename, password: password)
            return .init(identity: secIdentity)
        }

        /// Load P12 file
        private static func loadP12(filename: String, password: String) throws -> SecIdentity {
            let data = try Data(contentsOf: URL(fileURLWithPath: filename))
            let options: [String: String] = [kSecImportExportPassphrase as String: password]
            var rawItems: CFArray?
            guard SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems) == errSecSuccess else { throw TSTLSConfiguration.Error.invalidData }
            let items = rawItems! as! [[String: Any]]
            guard let firstItem = items.first,
                  let identity = firstItem[kSecImportItemIdentity as String] as! SecIdentity? else {
                      throw TSTLSConfiguration.Error.invalidData
                  }
            return identity
        }
    }

    /// The minimum TLS version to allow in negotiation. Defaults to tlsv1.
    public var minimumTLSVersion: tls_protocol_version_t

    /// The maximum TLS version to allow in negotiation. If nil, there is no upper limit. Defaults to nil.
    public var maximumTLSVersion: tls_protocol_version_t?

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
    public init(
        minimumTLSVersion: tls_protocol_version_t = .TLSv10,
        maximumTLSVersion: tls_protocol_version_t? = nil,
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
    ///   - p12: P12 filename
    ///   - p12Password: Password for P12
    ///   - trustRoots: The trust roots to use to validate certificates
    ///   - applicationProtocols: The application protocols to use in the connection
    ///   - certificateVerification: Should certificates be verified
    public init(
        minimumTLSVersion: tls_protocol_version_t = .TLSv10,
        maximumTLSVersion: tls_protocol_version_t? = nil,
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
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, self.minimumTLSVersion)
        } else {
            sec_protocol_options_set_tls_min_version(options.securityProtocolOptions, self.minimumTLSVersion.sslProtocol)
        }

        // maximum TLS protocol
        if let maximumTLSVersion = self.maximumTLSVersion {
            if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, maximumTLSVersion)
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
#endif
