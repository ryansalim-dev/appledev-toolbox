import Foundation
import ToolboxCore

/// Collects sources, binaries, manifests and Info.plists for the privacy check.
enum PrivacyScanRunner {
    struct Result {
        var findings: [PrivacyFinding]
        var scannedFiles: Int
        var manifestPaths: [String]
        var missingCategories: [RequiredReasonCategory]
    }

    /// Third-party and build folders: SDKs ship their own manifests, so their code isn't attributed to the app.
    static let skippedFolders: Set<String> = [".git", ".build", "build", "DerivedData", "Pods", "Carthage", "SourcePackages", "node_modules", "Tests"]

    static func scan(_ url: URL) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            if PlistLoader.isAppBundle(url) {
                return try await scanApp(PlistLoader.resolveApp(url))
            }
            return try scanProject(url)
        }.value
    }

    // MARK: - Project folder

    static func scanProject(_ root: URL) throws -> Result {
        var detections = PrivacyScanner.Detections()
        var manifests: [String: PrivacyManifest] = [:]
        var infoKeys: [String: PlistValue]?
        var buildSettings = ""
        var scanned = 0

        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else { throw PlistLoader.LoadError(description: "Couldn't read \(root.path).") }

        for case let file as URL in enumerator {
            if skippedFolders.contains(file.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            let ext = file.pathExtension.lowercased()
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size < 4_000_000 else { continue }

            if PrivacyScanner.sourceExtensions.contains(ext), let text = try? String(contentsOf: file, encoding: .utf8) {
                PrivacyScanner.scanSource(text, fileName: relative, into: &detections)
                scanned += 1
            } else if ext == "xcprivacy", let data = try? Data(contentsOf: file), let manifest = try? PrivacyManifest.parse(data) {
                manifests[relative] = manifest
            } else if file.lastPathComponent == "Info.plist", let data = try? Data(contentsOf: file),
                      let dict = (try? PlistDocument.parse(data))?.root.dictionaryValue {
                infoKeys = (infoKeys ?? [:]).merging(dict) { a, _ in a }
            } else if file.lastPathComponent == "project.pbxproj", let text = try? String(contentsOf: file, encoding: .utf8) {
                buildSettings += text
            }
            if scanned > 20_000 { break }
        }

        let input = PrivacyScanner.Input(detections: detections, manifests: manifests, infoPlistKeys: infoKeys, buildSettingsText: buildSettings)
        return result(input, scanned: scanned)
    }

    // MARK: - Built app

    static func scanApp(_ app: URL) throws -> Result {
        let fm = FileManager.default
        let infoURL = AppBundleFiles.infoPlistURL(inApp: app)
        let info = (try? PlistDocument.parse(Data(contentsOf: infoURL)))?.root.dictionaryValue
        let isMac = infoURL.path.hasSuffix("Contents/Info.plist")

        var detections = PrivacyScanner.Detections()
        var manifests: [String: PrivacyManifest] = [:]
        var extra: [PrivacyFinding] = []
        var scanned = 0

        if let exe = info?["CFBundleExecutable"]?.stringValue {
            let binary = isMac ? app.appendingPathComponent("Contents/MacOS/\(exe)") : app.appendingPathComponent(exe)
            if let data = try? Data(contentsOf: binary, options: .mappedIfSafe) {
                PrivacyScanner.scanBinary(data, name: exe, into: &detections)
                scanned += 1
            }
        }
        if let manifestURL = AppBundleFiles.privacyManifestURL(inApp: app),
           let manifest = try? PrivacyManifest.parse(Data(contentsOf: manifestURL)) {
            manifests[manifestURL.lastPathComponent] = manifest
        }

        // Each embedded framework needs its own manifest if it uses required-reason APIs.
        let frameworksDir = isMac ? app.appendingPathComponent("Contents/Frameworks") : app.appendingPathComponent("Frameworks")
        for framework in (try? fm.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil)) ?? [] where framework.pathExtension == "framework" {
            let name = framework.deletingPathExtension().lastPathComponent
            let resources = isMac ? framework.appendingPathComponent("Resources") : framework
            let binary = isMac ? framework.appendingPathComponent("Versions/Current/\(name)") : framework.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: binary, options: .mappedIfSafe) else { continue }
            scanned += 1
            var own = PrivacyScanner.Detections()
            PrivacyScanner.scanBinary(data, name: "\(name).framework", into: &own)
            let usesRequiredReason = own.keys.contains { if case .requiredReason = $0 { return true }; return false }
            let manifestURL = resources.appendingPathComponent("PrivacyInfo.xcprivacy")
            if let manifest = try? PrivacyManifest.parse(Data(contentsOf: manifestURL)) {
                extra += PrivacyScanner.report(.init(detections: own.filter { if case .requiredReason = $0.key { return true }; return false },
                                                     manifests: ["\(name).framework": manifest], infoPlistKeys: nil))
                    .filter { $0.severity != .info }
                    .map { var f = $0; f.title = "\(name).framework: " + f.title; return f }
            } else if usesRequiredReason {
                extra.append(.init(severity: .warning, title: "\(name).framework has no privacy manifest",
                                   detail: "It appears to use required-reason APIs. Update the SDK to a version that ships PrivacyInfo.xcprivacy; Apple requires one for commonly used SDKs.",
                                   evidence: ["\(name).framework"]))
            }
            // Permission prompts from SDK code still need the app's usage descriptions.
            for (target, places) in own { if case .usageDescription = target { detections[target, default: []] += places } }
        }

        var r = result(.init(detections: detections, manifests: manifests, infoPlistKeys: info ?? [:]), scanned: scanned)
        r.findings = (r.findings + extra).sorted { ($0.severity, $0.title) < ($1.severity, $1.title) }
        return r
    }

    private static func result(_ input: PrivacyScanner.Input, scanned: Int) -> Result {
        let findings = PrivacyScanner.report(input)
        let declared = Set(input.manifests.values.flatMap { $0.accessedAPIs.map(\.category) })
        let missing = RequiredReasonCategory.allCases.filter {
            input.detections[.requiredReason($0)] != nil && !declared.contains($0.rawValue)
        }
        return Result(findings: findings, scannedFiles: scanned, manifestPaths: input.manifests.keys.sorted(), missingCategories: missing)
    }

    /// XML to paste into NSPrivacyAccessedAPITypes for the missing categories.
    static func snippet(for categories: [RequiredReasonCategory]) -> String {
        categories.map { c in
            """
            <dict>
            \t<key>NSPrivacyAccessedAPIType</key>
            \t<string>\(c.rawValue)</string>
            \t<key>NSPrivacyAccessedAPITypeReasons</key>
            \t<array>
            \t\t<string>\(c.suggestedReason)</string>
            \t</array>
            </dict>
            """
        }.joined(separator: "\n")
    }
}
