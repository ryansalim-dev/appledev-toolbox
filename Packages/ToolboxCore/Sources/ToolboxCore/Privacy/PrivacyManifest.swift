import Foundation

/// A parsed `PrivacyInfo.xcprivacy`.
public struct PrivacyManifest: Equatable, Sendable {
    public struct AccessedAPI: Equatable, Sendable {
        public var category: String
        public var reasons: [String]
    }

    public struct CollectedDataType: Equatable, Sendable {
        public var type: String
        public var linked: Bool?
        public var tracking: Bool?
        public var purposes: [String]
    }

    public var tracking: Bool?
    public var trackingDomains: [String]
    public var collectedDataTypes: [CollectedDataType]
    public var accessedAPIs: [AccessedAPI]

    public init(tracking: Bool? = nil, trackingDomains: [String] = [], collectedDataTypes: [CollectedDataType] = [], accessedAPIs: [AccessedAPI] = []) {
        self.tracking = tracking
        self.trackingDomains = trackingDomains
        self.collectedDataTypes = collectedDataTypes
        self.accessedAPIs = accessedAPIs
    }

    public init(_ root: PlistValue) {
        let dict = root.dictionaryValue ?? [:]
        tracking = dict["NSPrivacyTracking"]?.boolValue
        trackingDomains = dict["NSPrivacyTrackingDomains"]?.arrayValue?.compactMap(\.stringValue) ?? []
        collectedDataTypes = (dict["NSPrivacyCollectedDataTypes"]?.arrayValue ?? []).compactMap { item in
            guard let d = item.dictionaryValue else { return nil }
            return CollectedDataType(
                type: d["NSPrivacyCollectedDataType"]?.stringValue ?? "",
                linked: d["NSPrivacyCollectedDataTypeLinked"]?.boolValue,
                tracking: d["NSPrivacyCollectedDataTypeTracking"]?.boolValue,
                purposes: d["NSPrivacyCollectedDataTypePurposes"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        }
        accessedAPIs = (dict["NSPrivacyAccessedAPITypes"]?.arrayValue ?? []).compactMap { item in
            guard let d = item.dictionaryValue else { return nil }
            return AccessedAPI(
                category: d["NSPrivacyAccessedAPIType"]?.stringValue ?? "",
                reasons: d["NSPrivacyAccessedAPITypeReasons"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        }
    }

    public static func parse(_ data: Data) throws -> PrivacyManifest {
        PrivacyManifest(try PlistDocument.parse(data).root)
    }

    /// Problems in the manifest itself, independent of what the code uses.
    public func validate() -> [PrivacyFinding] {
        var findings: [PrivacyFinding] = []
        for api in accessedAPIs {
            guard let category = RequiredReasonCategory(rawValue: api.category) else {
                findings.append(.init(severity: .error, title: "Unknown API category \"\(api.category)\"",
                                      detail: "NSPrivacyAccessedAPIType must be one of Apple's required-reason categories."))
                continue
            }
            if api.reasons.isEmpty {
                findings.append(.init(severity: .error, title: "\(category.title): no reason given",
                                      detail: "Add at least one approved reason code to NSPrivacyAccessedAPITypeReasons."))
            }
            for reason in api.reasons where !category.reasonCodes.keys.contains(reason) {
                findings.append(.init(severity: .error, title: "\(category.title): \"\(reason)\" isn't a valid reason",
                                      detail: "Valid codes: " + category.reasonCodes.keys.sorted().joined(separator: ", ") + "."))
            }
        }
        if tracking == true, trackingDomains.isEmpty {
            findings.append(.init(severity: .warning, title: "Tracking is on but no tracking domains are listed",
                                  detail: "If the app or an SDK connects to tracking domains, list them in NSPrivacyTrackingDomains."))
        }
        if tracking != true, !trackingDomains.isEmpty {
            findings.append(.init(severity: .warning, title: "Tracking domains listed while NSPrivacyTracking is false",
                                  detail: "iOS blocks connections to tracking domains unless the user grants tracking permission; set NSPrivacyTracking to true if you track."))
        }
        for (i, item) in collectedDataTypes.enumerated() {
            if item.type.isEmpty {
                findings.append(.init(severity: .error, title: "Collected data type \(i + 1) has no NSPrivacyCollectedDataType", detail: ""))
            }
            if item.linked == nil || item.tracking == nil || item.purposes.isEmpty {
                findings.append(.init(severity: .error, title: "Collected data type \(item.type.isEmpty ? String(i + 1) : item.type) is incomplete",
                                      detail: "Each entry needs Linked, Tracking and at least one Purpose."))
            }
        }
        return findings
    }
}

public struct PrivacyFinding: Equatable, Sendable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case error = 0, warning, info
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { "\(severity)|\(title)|\(evidence.first ?? "")" }
    public var severity: Severity
    public var title: String
    public var detail: String
    /// Where it was found: `File.swift:42` or a binary name.
    public var evidence: [String]

    public init(severity: Severity, title: String, detail: String, evidence: [String] = []) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.evidence = evidence
    }
}

/// Apple's required-reason API categories and their approved reason codes.
public enum RequiredReasonCategory: String, CaseIterable, Sendable {
    case fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"
    case systemBootTime = "NSPrivacyAccessedAPICategorySystemBootTime"
    case diskSpace = "NSPrivacyAccessedAPICategoryDiskSpace"
    case activeKeyboards = "NSPrivacyAccessedAPICategoryActiveKeyboards"
    case userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"

    public var title: String {
        switch self {
        case .fileTimestamp: return "File timestamp APIs"
        case .systemBootTime: return "System boot time APIs"
        case .diskSpace: return "Disk space APIs"
        case .activeKeyboards: return "Active keyboard APIs"
        case .userDefaults: return "User defaults APIs"
        }
    }

    /// Reason code → short description.
    public var reasonCodes: [String: String] {
        switch self {
        case .fileTimestamp:
            return ["DDA9.1": "Show timestamps to the user", "C617.1": "Files in the app container, app group or CloudKit container",
                    "3B52.1": "Files the user granted access to", "0A2A.1": "Third-party SDK wrapper"]
        case .systemBootTime:
            return ["35F9.1": "Measure elapsed time between in-app events", "8FFB.1": "Calculate absolute timestamps for in-app events",
                    "3D61.1": "Optional user-submitted bug reports"]
        case .diskSpace:
            return ["85F4.1": "Show disk space to the user", "E174.1": "Check space before writing files",
                    "7D9E.1": "Optional user-submitted bug reports", "B728.1": "Health research app"]
        case .activeKeyboards:
            return ["3EC4.1": "Custom keyboard app", "54BD.1": "Customize UI for the active keyboard"]
        case .userDefaults:
            return ["CA92.1": "Read/write data only accessible to the app itself", "1C8F.1": "App group data",
                    "C56D.1": "Third-party SDK wrapper", "AC6B.1": "Managed app configuration (MDM)"]
        }
    }

    /// The usual reason for an app's own use, suggested when a declaration is missing.
    public var suggestedReason: String {
        switch self {
        case .fileTimestamp: return "C617.1"
        case .systemBootTime: return "35F9.1"
        case .diskSpace: return "E174.1"
        case .activeKeyboards: return "54BD.1"
        case .userDefaults: return "CA92.1"
        }
    }
}
