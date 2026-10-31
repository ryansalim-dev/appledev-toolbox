import Foundation
import ToolboxCore

/// What to show from an app bundle in the Plist tool.
enum BundlePlistSource: String, CaseIterable, Identifiable {
    case infoPlist = "Info.plist"
    case entitlements = "Entitlements"
    case embeddedProfile = "Profile entitlements"
    case privacyManifest = "Privacy manifest"

    var id: String { rawValue }
}

enum PlistLoader {
    struct LoadError: Error, CustomStringConvertible {
        let description: String
    }

    static func isAppBundle(_ url: URL) -> Bool {
        ["app", "ipa"].contains(url.pathExtension.lowercased())
    }

    /// Returns the `.app` to read from: the bundle itself, or one unzipped from an `.ipa` into a temp folder.
    static func resolveApp(_ url: URL) async throws -> URL {
        guard url.pathExtension.lowercased() == "ipa" else { return url }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleDevToolbox-ipa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try await CommandRunner.run("/usr/bin/ditto", ["-x", "-k", url.path, destination.path])
        guard let app = AppBundleFiles.appInUnzippedIPA(destination) else {
            throw LoadError(description: "No Payload/*.app found inside \(url.lastPathComponent).")
        }
        return app
    }

    static func load(_ source: BundlePlistSource, app: URL) async throws -> PlistDocument {
        switch source {
        case .infoPlist:
            return try PlistDocument.parse(Data(contentsOf: AppBundleFiles.infoPlistURL(inApp: app)))
        case .entitlements:
            return try await entitlements(of: app)
        case .embeddedProfile:
            guard let url = AppBundleFiles.embeddedProfileURL(inApp: app) else {
                throw LoadError(description: "This app has no embedded provisioning profile (App Store and Simulator builds usually don't).")
            }
            let profile = try ProvisioningProfile.parse(Data(contentsOf: url), fileURL: url)
            return PlistDocument(root: .dictionary(profile.entitlements))
        case .privacyManifest:
            guard let url = AppBundleFiles.privacyManifestURL(inApp: app) else {
                throw LoadError(description: "This app has no PrivacyInfo.xcprivacy at its top level.")
            }
            return try PlistDocument.parse(Data(contentsOf: url))
        }
    }

    /// The entitlements a binary was actually signed with, via `codesign`.
    static func entitlements(of path: URL) async throws -> PlistDocument {
        let output = try await CommandRunner.run("/usr/bin/codesign", AppBundleFiles.codesignEntitlementsArguments(path: path.path))
        guard output.contains("<plist") else {
            throw LoadError(description: "\(path.lastPathComponent) has no signed entitlements (is it signed?).")
        }
        return try PlistDocument.parse(Data(output.utf8))
    }

    /// Loads any file for comparison: plists directly, apps/IPAs as their entitlements, profiles as their entitlements.
    static func loadForComparison(_ url: URL) async throws -> PlistDocument {
        let ext = url.pathExtension.lowercased()
        if isAppBundle(url) {
            return try await entitlements(of: resolveApp(url))
        }
        let data = try Data(contentsOf: url)
        if ext == "mobileprovision" || ext == "provisionprofile" {
            return PlistDocument(root: .dictionary(try ProvisioningProfile.parse(data).entitlements))
        }
        return try PlistDocument.parse(data)
    }
}
