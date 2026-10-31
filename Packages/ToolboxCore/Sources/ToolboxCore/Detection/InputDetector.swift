import Foundation

/// What a pasted string or dropped file contains, so the app can open the right tool.
public enum DetectedContent: String, Equatable, Sendable, CaseIterable {
    case provisioningProfile
    case crashLog
    case propertyList
    case jwt
    case json
    case unixTimestamp
    case base64
    case unknown
}

public enum InputDetector {
    /// Detects pasted text. Checks run from most to least specific.
    public static func detect(text: String) -> DetectedContent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        if JWTDecoder.looksLikeJWT(trimmed) { return .jwt }
        if CrashReportParser.looksLikeIPS(trimmed) { return .crashLog }
        if trimmed.hasPrefix("<?xml"), trimmed.contains("<plist") { return .propertyList }
        if let first = trimmed.first, first == "{" || first == "[", (try? JSONParser.parse(trimmed)) != nil { return .json }
        if looksLikeTimestamp(trimmed) { return .unixTimestamp }
        if looksLikeBase64(trimmed) { return .base64 }
        return .unknown
    }

    /// Detects a dropped or opened file by extension first, then by content.
    public static func detect(fileExtension ext: String, data: Data) -> DetectedContent {
        switch ext.lowercased() {
        case "mobileprovision", "provisionprofile": return .provisioningProfile
        case "ips": return .crashLog
        case "plist", "entitlements", "xcprivacy": return .propertyList
        case "json": return .json
        default: break
        }
        if data.starts(with: Data("bplist".utf8)) { return .propertyList }
        // A CMS-wrapped profile with an unexpected extension.
        if data.first == 0x30, ProvisioningProfile.extractPlist(from: data) != nil,
           let s = String(data: data.prefix(64 * 1024), encoding: .isoLatin1), s.contains("<key>ProvisionedDevices</key>") || s.contains("<key>ExpirationDate</key>") {
            return .provisioningProfile
        }
        guard let text = String(data: data, encoding: .utf8) else { return .unknown }
        return detect(text: text)
    }

    static func looksLikeTimestamp(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, (9...19).contains(whole.count), whole.allSatisfy(\.isNumber) else { return false }
        return parts.count == 1 || parts[1].allSatisfy(\.isNumber)
    }

    static func looksLikeBase64(_ s: String) -> Bool {
        // Require some length and a non-trivial mix so plain words aren't treated as Base64.
        let compact = s.filter { !$0.isWhitespace }
        guard compact.count >= 12 else { return false }
        guard (try? Base64Tool.decode(compact)) != nil else { return false }
        let hasDigitOrSymbol = compact.contains(where: { $0.isNumber || "+/=-_".contains($0) })
        let hasUpper = compact.contains(where: \.isUppercase)
        let hasLower = compact.contains(where: \.isLowercase)
        return hasUpper && hasLower && (hasDigitOrSymbol || compact.count % 4 == 0)
    }
}
