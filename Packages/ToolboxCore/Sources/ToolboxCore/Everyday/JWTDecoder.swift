import Foundation

/// Decodes (but does not verify) a JSON Web Token.
public struct DecodedJWT: Equatable, Sendable {
    public let header: JSONValue
    public let payload: JSONValue
    /// The raw Base64URL signature segment.
    public let signature: String

    public var algorithm: String? { header["alg"]?.stringValue }
    public var keyID: String? { header["kid"]?.stringValue }
    public var issuer: String? { payload["iss"]?.stringValue }
    public var subject: String? { payload["sub"]?.stringValue }
    public var audience: [String] {
        if let list = payload["aud"]?.arrayValue { return list.compactMap(\.stringValue) }
        return payload["aud"]?.stringValue.map { [$0] } ?? []
    }
    public var issuedAt: Date? { date(for: "iat") }
    public var expiresAt: Date? { date(for: "exp") }
    public var notBefore: Date? { date(for: "nbf") }

    /// nil when the token has no `exp` claim.
    public func isExpired(at now: Date = Date()) -> Bool? {
        expiresAt.map { $0 <= now }
    }

    private func date(for claim: String) -> Date? {
        payload[claim]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
    }
}

public enum JWTDecoder {
    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case wrongSegmentCount(Int)
        case invalidBase64(segment: String)
        case invalidJSON(segment: String, detail: String)

        public var description: String {
            switch self {
            case .wrongSegmentCount(let n): return "A JWT has 3 parts separated by dots; this has \(n)."
            case .invalidBase64(let segment): return "The \(segment) isn't valid Base64URL."
            case .invalidJSON(let segment, let detail): return "The \(segment) isn't valid JSON: \(detail)"
            }
        }
    }

    public static func decode(_ token: String) throws -> DecodedJWT {
        var trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("bearer ") { trimmed = String(trimmed.dropFirst(7)) }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw DecodeError.wrongSegmentCount(parts.count) }
        return DecodedJWT(
            header: try decodeSegment(parts[0], name: "header"),
            payload: try decodeSegment(parts[1], name: "payload"),
            signature: parts[2]
        )
    }

    /// Cheap check used by input detection.
    public static func looksLikeJWT(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("eyJ"), parts[1].count > 0 else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
        return parts.allSatisfy { $0.allSatisfy { allowed.contains($0) } }
    }

    private static func decodeSegment(_ segment: String, name: String) throws -> JSONValue {
        guard let data = try? Base64Tool.decode(segment) else { throw DecodeError.invalidBase64(segment: name) }
        do {
            return try JSONParser.parse(data)
        } catch {
            throw DecodeError.invalidJSON(segment: name, detail: String(describing: error))
        }
    }
}
