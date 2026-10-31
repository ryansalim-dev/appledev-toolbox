import Foundation

enum ToolSection: String, CaseIterable, Identifiable {
    case signing = "Signing"
    case debugging = "Debugging"
    case appStore = "App Store"
    case everyday = "Everyday"

    var id: String { rawValue }
}

enum ToolID: String, CaseIterable, Identifiable, Hashable {
    case profiles
    case certificates
    case crashLogs
    case push
    case universalLinks
    case plist
    case privacy
    case appIcon
    case json
    case codable
    case jwt
    case base64
    case timestamp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profiles: return "Provisioning Profiles"
        case .certificates: return "Signing Certificates"
        case .crashLogs: return "Crash Logs"
        case .push: return "Push Tester"
        case .universalLinks: return "Universal Links"
        case .plist: return "Plist & Entitlements"
        case .privacy: return "Privacy Checker"
        case .appIcon: return "App Icon"
        case .json: return "JSON Formatter"
        case .codable: return "JSON → Codable"
        case .jwt: return "JWT Decoder"
        case .base64: return "Base64"
        case .timestamp: return "Timestamps"
        }
    }

    var systemImage: String {
        switch self {
        case .profiles: return "doc.badge.gearshape"
        case .certificates: return "checkmark.seal"
        case .crashLogs: return "exclamationmark.triangle"
        case .push: return "bell.badge"
        case .universalLinks: return "link"
        case .plist: return "list.bullet.rectangle"
        case .privacy: return "hand.raised"
        case .appIcon: return "app.dashed"
        case .json: return "curlybraces"
        case .codable: return "swift"
        case .jwt: return "key"
        case .base64: return "textformat.abc"
        case .timestamp: return "clock"
        }
    }

    var section: ToolSection {
        switch self {
        case .profiles, .certificates, .plist: return .signing
        case .crashLogs, .push, .universalLinks: return .debugging
        case .privacy, .appIcon: return .appStore
        case .json, .codable, .jwt, .base64, .timestamp: return .everyday
        }
    }

    /// Tools not built yet show a placeholder.
    var isAvailable: Bool {
        switch self {
        case .push, .universalLinks, .plist, .privacy, .appIcon: return false
        default: return true
        }
    }
}
