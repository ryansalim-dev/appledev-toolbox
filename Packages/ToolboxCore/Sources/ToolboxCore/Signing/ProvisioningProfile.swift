import Foundation

/// A parsed `.mobileprovision` / `.provisionprofile`.
public struct ProvisioningProfile: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case development = "Development"
        case adHoc = "Ad Hoc"
        case appStore = "App Store"
        case enterprise = "Enterprise"
    }

    public var id: String { uuid }

    public let name: String
    public let uuid: String
    public let appIDName: String?
    public let teamName: String?
    public let teamIdentifiers: [String]
    public let applicationIdentifierPrefix: [String]
    public let platforms: [String]
    public let creationDate: Date?
    public let expirationDate: Date
    public let provisionedDevices: [String]
    public let provisionsAllDevices: Bool
    public let isXcodeManaged: Bool
    public let entitlements: [String: PlistValue]
    /// DER-encoded certificates embedded in the profile.
    public let developerCertificates: [Data]
    /// The file the profile was loaded from, when known.
    public var fileURL: URL?

    public var kind: Kind {
        if provisionsAllDevices { return .enterprise }
        let getTaskAllow = entitlements["get-task-allow"]?.boolValue ?? false
        if getTaskAllow { return .development }
        return provisionedDevices.isEmpty ? .appStore : .adHoc
    }

    /// e.g. `ABCDE12345.com.example.app` (iOS) or from `com.apple.application-identifier` (macOS).
    public var applicationIdentifier: String? {
        entitlements["application-identifier"]?.stringValue
            ?? entitlements["com.apple.application-identifier"]?.stringValue
    }

    /// The bundle ID part of the application identifier (may be a wildcard like `com.example.*`).
    public var bundleIdentifier: String? {
        guard let appID = applicationIdentifier, let dot = appID.firstIndex(of: ".") else { return nil }
        return String(appID[appID.index(after: dot)...])
    }

    public var isWildcard: Bool { bundleIdentifier?.hasSuffix("*") ?? false }

    public func isExpired(at now: Date = Date()) -> Bool { expirationDate <= now }

    /// Whole days until expiry (negative once expired).
    public func daysUntilExpiry(from now: Date = Date()) -> Int {
        Int((expirationDate.timeIntervalSince(now) / 86_400).rounded(.down))
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noEmbeddedPlist
        case invalidPlist(String)
        public var description: String {
            switch self {
            case .noEmbeddedPlist: return "This file doesn't contain a provisioning profile."
            case .invalidPlist(let detail): return "The profile's contents couldn't be read: \(detail)"
            }
        }
    }

    /// Parses the raw contents of a profile file.
    ///
    /// Profiles are CMS-signed, but the payload is stored unencrypted, so we read the
    /// embedded XML plist directly. This works on every platform; verifying the
    /// signature itself (with `CMSDecoder` on macOS) is a separate, optional step.
    public static func parse(_ data: Data, fileURL: URL? = nil) throws -> ProvisioningProfile {
        guard let plist = extractPlist(from: data) else { throw ParseError.noEmbeddedPlist }
        let raw: RawProfile
        do {
            raw = try PropertyListDecoder().decode(RawProfile.self, from: plist)
        } catch {
            throw ParseError.invalidPlist(String(describing: error))
        }
        return ProvisioningProfile(
            name: raw.Name,
            uuid: raw.UUID,
            appIDName: raw.AppIDName,
            teamName: raw.TeamName,
            teamIdentifiers: raw.TeamIdentifier ?? [],
            applicationIdentifierPrefix: raw.ApplicationIdentifierPrefix ?? [],
            platforms: raw.Platform ?? [],
            creationDate: raw.CreationDate,
            expirationDate: raw.ExpirationDate,
            provisionedDevices: raw.ProvisionedDevices ?? [],
            provisionsAllDevices: raw.ProvisionsAllDevices ?? false,
            isXcodeManaged: raw.IsXcodeManaged ?? false,
            entitlements: raw.Entitlements ?? [:],
            developerCertificates: raw.DeveloperCertificates ?? [],
            fileURL: fileURL
        )
    }

    /// Finds the `<?xml … </plist>` payload inside the CMS envelope (or returns the data as-is if it's already a plist).
    public static func extractPlist(from data: Data) -> Data? {
        let start = Data("<?xml".utf8)
        let end = Data("</plist>".utf8)
        guard let startRange = data.range(of: start),
              let endRange = data.range(of: end, in: startRange.upperBound..<data.endIndex)
        else {
            return data.starts(with: Data("bplist".utf8)) ? data : nil
        }
        return data.subdata(in: startRange.lowerBound..<endRange.upperBound)
    }

    private struct RawProfile: Decodable {
        let Name: String
        let UUID: String
        let AppIDName: String?
        let TeamName: String?
        let TeamIdentifier: [String]?
        let ApplicationIdentifierPrefix: [String]?
        let Platform: [String]?
        let CreationDate: Date?
        let ExpirationDate: Date
        let ProvisionedDevices: [String]?
        let ProvisionsAllDevices: Bool?
        let IsXcodeManaged: Bool?
        let Entitlements: [String: PlistValue]?
        let DeveloperCertificates: [Data]?
    }
}

/// Loads every profile in Xcode's profile folders and points out clean-up candidates.
public struct ProfileLibrary: Sendable {
    public let profiles: [ProvisioningProfile]
    /// Files that looked like profiles but couldn't be parsed.
    public let failures: [URL]

    public init(profiles: [ProvisioningProfile], failures: [URL]) {
        self.profiles = profiles
        self.failures = failures
    }

    /// Xcode 16+ stores profiles under UserData; older Xcodes used MobileDevice.
    public static func defaultDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true),
            home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles", isDirectory: true),
        ]
    }

    public static func load(from directories: [URL]) -> ProfileLibrary {
        let fm = FileManager.default
        var profiles: [ProvisioningProfile] = []
        var failures: [URL] = []
        var seen: Set<String> = []
        for directory in directories {
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for file in files where ["mobileprovision", "provisionprofile"].contains(file.pathExtension.lowercased()) {
                guard let data = try? Data(contentsOf: file), let profile = try? ProvisioningProfile.parse(data, fileURL: file) else {
                    failures.append(file)
                    continue
                }
                // The same profile can sit in both folders; keep the first copy.
                if seen.insert(profile.uuid).inserted { profiles.append(profile) }
            }
        }
        profiles.sort { $0.expirationDate < $1.expirationDate }
        return ProfileLibrary(profiles: profiles, failures: failures)
    }

    public func expired(at now: Date = Date()) -> [ProvisioningProfile] {
        profiles.filter { $0.isExpired(at: now) }
    }

    /// Profiles for the same app ID and kind where a newer one exists: safe to delete.
    public func superseded() -> [ProvisioningProfile] {
        let groups = Dictionary(grouping: profiles) { "\($0.applicationIdentifier ?? $0.name)|\($0.kind.rawValue)" }
        return groups.values.flatMap { group -> [ProvisioningProfile] in
            let newestFirst = group.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            return Array(newestFirst.dropFirst())
        }
        .sorted { $0.expirationDate < $1.expirationDate }
    }
}
