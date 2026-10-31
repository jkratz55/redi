import Foundation
import Security

/// Loading CA certificates and client identities from the files users typically have for Redis TLS.
public enum CertificateLoader {
    public enum Error: Swift.Error, Sendable, Hashable, CustomStringConvertible {
        case noCertificatesFound
        case invalidCertificate
        case pkcs12(OSStatus)
        case pkcs12NoIdentity
        case invalidPrivateKey(OSStatus)
        case keyDoesNotMatchCertificate

        public var description: String {
            switch self {
            case .noCertificatesFound: "No certificates found in file."
            case .invalidCertificate: "The file isn't a valid X.509 certificate."
            case .invalidPrivateKey(let status): "The private key couldn't be read (\(status)). Use an unencrypted PEM key."
            case .keyDoesNotMatchCertificate: "The private key doesn't match the client certificate."
            case .pkcs12(let status): SecCopyErrorMessageString(status, nil) as String? ?? "PKCS#12 import failed (\(status))."
            case .pkcs12NoIdentity: "The PKCS#12 file doesn't contain a certificate with its private key."
            }
        }
    }

    /// DER blobs for every certificate in a PEM bundle, or the file itself if it's already DER.
    public static func certificateDER(from data: Data) throws(Error) -> [Data] {
        let ders: [Data]
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") {
            ders = pemBlocks(in: text, label: "CERTIFICATE")
        } else {
            ders = [data]
        }
        guard !ders.isEmpty else { throw .noCertificatesFound }
        for der in ders where SecCertificateCreateWithData(nil, der as CFData) == nil {
            throw .invalidCertificate
        }
        return ders
    }

    /// Imports a client identity (certificate + private key) from a `.p12` / `.pfx` file.
    public static func identity(pkcs12 data: Data, password: String) throws(Error) -> TLSIdentity {
        var items: CFArray?
        // Memory-only: never add the identity to the user's login keychain as a side effect.
        let options = [kSecImportExportPassphrase as String: password,
                       kSecImportToMemoryOnly as String: true] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess else { throw .pkcs12(status) }
        guard let entries = items as? [[String: Any]],
              let first = entries.first,
              let value = first[kSecImportItemIdentity as String] else {
            throw .pkcs12NoIdentity
        }
        // swiftlint:disable:next force_cast
        return TLSIdentity(value as! SecIdentity)
    }

    /// Builds a client identity from a PEM certificate and PEM private key (PKCS#1, PKCS#8 or SEC1),
    /// entirely in memory. Nothing is added to a keychain.
    public static func identity(certificatePEM: String, privateKeyPEM: String) throws(Error) -> TLSIdentity {
        guard let certificateDER = try certificateDER(from: Data(certificatePEM.utf8)).first,
              let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw .invalidCertificate
        }
        var format = SecExternalFormat.formatUnknown
        var type = SecExternalItemType.itemTypePrivateKey
        var items: CFArray?
        let status = SecItemImport(Data(privateKeyPEM.utf8) as CFData, nil, &format, &type, [], nil, nil, &items)
        guard status == errSecSuccess,
              let imported = items as? [AnyObject],
              let first = imported.first,
              CFGetTypeID(first) == SecKeyGetTypeID() else {
            throw .invalidPrivateKey(status)
        }
        // swiftlint:disable:next force_cast
        let key = first as! SecKey
        guard let identity = SecIdentityCreate(nil, certificate, key) else { throw .keyDoesNotMatchCertificate }
        return TLSIdentity(identity)
    }

    /// Base64 payloads of `-----BEGIN <label>-----` blocks.
    static func pemBlocks(in text: String, label: String) -> [Data] {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        var blocks: [Data] = []
        var remainder = text[...]
        while let start = remainder.range(of: begin), let stop = remainder.range(of: end, range: start.upperBound..<remainder.endIndex) {
            let body = remainder[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(body)) { blocks.append(der) }
            remainder = remainder[stop.upperBound...]
        }
        return blocks
    }
}
