import Foundation
import Security

struct CertificateSummary: Identifiable, Hashable {
    var id: Data { der }
    let der: Data
    let commonName: String
    let expiresAt: Date?
    /// True when the Keychain holds the matching private key (i.e. you can sign with it).
    var hasPrivateKey = false

    var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }

    /// Apple signing certificates, by their common-name prefix.
    var isAppleSigningCertificate: Bool {
        ["Apple Development", "Apple Distribution", "iPhone Developer", "iPhone Distribution",
         "Mac Developer", "Developer ID Application", "Developer ID Installer",
         "3rd Party Mac Developer", "Apple Push Services"].contains { commonName.hasPrefix($0) }
    }
}

enum CertificateInspector {
    static func summary(der: Data) -> CertificateSummary? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return summary(certificate)
    }

    static func summary(_ certificate: SecCertificate) -> CertificateSummary {
        let der = SecCertificateCopyData(certificate) as Data
        let name = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Unknown certificate"
        return CertificateSummary(der: der, commonName: name, expiresAt: notAfter(certificate))
    }

    private static func notAfter(_ certificate: SecCertificate) -> Date? {
        let key = kSecOIDX509V1ValidityNotAfter as String
        guard let values = SecCertificateCopyValues(certificate, [key] as CFArray, nil) as? [String: Any],
              let entry = values[key] as? [String: Any],
              let number = entry[kSecPropertyKeyValue as String] as? NSNumber
        else { return nil }
        // The value is seconds since the Core Foundation reference date (2001-01-01).
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }

    /// Apple signing certificates in the user's Keychain, newest expiry first.
    static func keychainSigningCertificates() -> [CertificateSummary] {
        let identityDERs = Set(copyAll(kSecClassIdentity).compactMap { item -> Data? in
            var certificate: SecCertificate?
            // swiftlint:disable:next force_cast
            guard SecIdentityCopyCertificate(item as! SecIdentity, &certificate) == errSecSuccess, let certificate else { return nil }
            return SecCertificateCopyData(certificate) as Data
        })

        var seen = Set<Data>()
        return copyAll(kSecClassCertificate)
            // swiftlint:disable:next force_cast
            .map { summary($0 as! SecCertificate) }
            .filter { $0.isAppleSigningCertificate && seen.insert($0.der).inserted }
            .map { var s = $0; s.hasPrivateKey = identityDERs.contains(s.der); return s }
            .sorted { ($0.expiresAt ?? .distantPast) > ($1.expiresAt ?? .distantPast) }
    }

    private static func copyAll(_ itemClass: CFString) -> [AnyObject] {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [AnyObject]
        else { return [] }
        return items
    }
}
