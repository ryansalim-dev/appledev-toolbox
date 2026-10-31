import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Token-based APNs authentication: an ES256-signed JWT made from a `.p8` key.
public struct APNsSigningKey: Sendable {
    public enum KeyError: Error, Equatable, CustomStringConvertible {
        case invalidKey(String)
        case signingUnavailable

        public var description: String {
            switch self {
            case .invalidKey(let detail): return "This isn't a valid APNs .p8 key: \(detail)"
            case .signingUnavailable: return "Signing needs CryptoKit, which isn't available on this platform."
            }
        }
    }

    /// 10-character Key ID from the developer portal.
    public let keyID: String
    /// 10-character Team ID.
    public let teamID: String
    let pem: String

    public init(pem: String, keyID: String, teamID: String) throws {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("-----BEGIN PRIVATE KEY-----"), trimmed.contains("-----END PRIVATE KEY-----") else {
            throw KeyError.invalidKey("expected a PEM block starting with -----BEGIN PRIVATE KEY-----")
        }
        #if canImport(CryptoKit)
        do {
            _ = try P256.Signing.PrivateKey(pemRepresentation: trimmed)
        } catch {
            throw KeyError.invalidKey(String(describing: error))
        }
        #endif
        self.pem = trimmed
        self.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.teamID = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Apple names downloaded keys `AuthKey_<KEYID>.p8`; returns that Key ID if the name matches.
    public static func keyID(fromFileName name: String) -> String? {
        guard name.hasPrefix("AuthKey_"), name.hasSuffix(".p8") else { return nil }
        let id = name.dropFirst("AuthKey_".count).dropLast(".p8".count)
        return id.count == 10 && id.allSatisfy({ $0.isLetter || $0.isNumber }) ? String(id) : nil
    }

    /// The unsigned `header.claims` part of the JWT.
    public func signingInput(issuedAt: Date) -> String {
        let header = #"{"alg":"ES256","kid":"\#(keyID)"}"#
        let claims = #"{"iss":"\#(teamID)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#
        return Base64Tool.encode(header, urlSafe: true, padded: false) + "." + Base64Tool.encode(claims, urlSafe: true, padded: false)
    }

    /// A signed provider token, valid for up to an hour.
    public func makeToken(issuedAt: Date = Date()) throws -> String {
        #if canImport(CryptoKit)
        let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        let input = signingInput(issuedAt: issuedAt)
        // JWS ES256 wants the raw 64-byte r||s signature, not DER.
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        return input + "." + Base64Tool.encode(signature, urlSafe: true, padded: false)
        #else
        throw KeyError.signingUnavailable
        #endif
    }
}

/// Reuses a provider token for 50 minutes. APNs rejects tokens older than an hour,
/// and also rejects refreshing more than once every 20 minutes.
public struct APNsTokenCache: Sendable {
    public static let lifetime: TimeInterval = 50 * 60

    private var token: String?
    private var issuedAt: Date?
    private var keyFingerprint: String?

    public init() {}

    public mutating func token(for key: APNsSigningKey, now: Date = Date()) throws -> String {
        let fingerprint = key.keyID + "|" + key.teamID + "|" + String(key.pem.hashValue)
        if let token, let issuedAt, keyFingerprint == fingerprint, now.timeIntervalSince(issuedAt) < Self.lifetime {
            return token
        }
        let fresh = try key.makeToken(issuedAt: now)
        token = fresh
        issuedAt = now
        keyFingerprint = fingerprint
        return fresh
    }
}
