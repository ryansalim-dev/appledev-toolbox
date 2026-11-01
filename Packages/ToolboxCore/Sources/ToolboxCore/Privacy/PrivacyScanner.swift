import Foundation

/// Finds required-reason API use and permission prompts in source code or compiled binaries,
/// then checks them against privacy manifests and Info.plist usage descriptions.
///
/// Detection is token-based: fast, offline, and easy to update (the rules are data), but it can
/// report false positives. Every finding lists where it was seen so a developer can judge.
public enum PrivacyScanner {
    public enum Target: Hashable, Sendable {
        case requiredReason(RequiredReasonCategory)
        /// An Info.plist key such as `NSCameraUsageDescription`.
        case usageDescription(String)
    }

    public struct Rule: Sendable {
        public let target: Target
        /// Identifiers to look for in Swift / Objective-C / C source.
        public let sourceTokens: [String]
        /// Symbol or selector names to look for in a Mach-O binary's string tables.
        public let binaryTokens: [String]
    }

    public static let rules: [Rule] = [
        // Required-reason APIs
        Rule(target: .requiredReason(.fileTimestamp),
             // Specific spellings only: a model's own `creationDate` property isn't a file timestamp API.
             sourceTokens: ["FileAttributeKey.creationDate", "FileAttributeKey.modificationDate", "[.creationDate]",
                            "[.modificationDate]", "fileModificationDate", "contentModificationDateKey", "creationDateKey",
                            "NSFileCreationDate", "NSFileModificationDate", "getattrlist", "getattrlistbulk", "fgetattrlist",
                            "getattrlistat", "fstat", "fstatat", "lstat"],
             binaryTokens: ["_stat", "_fstat", "_fstatat", "_lstat", "_getattrlist", "_getattrlistbulk", "_fgetattrlist",
                            "_getattrlistat", "NSFileCreationDate", "NSFileModificationDate", "NSURLContentModificationDateKey",
                            "NSURLCreationDateKey"]),
        Rule(target: .requiredReason(.systemBootTime),
             sourceTokens: ["systemUptime", "mach_absolute_time"],
             binaryTokens: ["systemUptime", "_mach_absolute_time"]),
        Rule(target: .requiredReason(.diskSpace),
             sourceTokens: ["volumeAvailableCapacityKey", "volumeAvailableCapacityForImportantUsageKey",
                            "volumeAvailableCapacityForOpportunisticUsageKey", "volumeTotalCapacityKey", "systemFreeSize",
                            "FileAttributeKey.systemSize", "[.systemSize]", "statfs", "statvfs", "fstatfs", "fstatvfs"],
             binaryTokens: ["NSURLVolumeAvailableCapacityKey", "NSURLVolumeAvailableCapacityForImportantUsageKey",
                            "NSURLVolumeAvailableCapacityForOpportunisticUsageKey", "NSURLVolumeTotalCapacityKey",
                            "NSFileSystemFreeSize", "NSFileSystemSize", "_statfs", "_statvfs", "_fstatfs", "_fstatvfs"]),
        Rule(target: .requiredReason(.activeKeyboards),
             sourceTokens: ["activeInputModes"],
             binaryTokens: ["activeInputModes"]),
        Rule(target: .requiredReason(.userDefaults),
             sourceTokens: ["UserDefaults", "NSUserDefaults", "@AppStorage"],
             binaryTokens: ["_OBJC_CLASS_$_NSUserDefaults"]),

        // Permission prompts that crash or get rejected without a usage description
        usage("NSCameraUsageDescription", ["AVCaptureDevice", "UIImagePickerController.SourceType.camera", "VNDocumentCameraViewController", "DataScannerViewController"]),
        usage("NSMicrophoneUsageDescription", ["requestRecordPermission", "AVAudioRecorder", "AVAudioApplication.requestRecordPermission"]),
        usage("NSPhotoLibraryUsageDescription", ["PHPhotoLibrary", "PHAsset"]),
        usage("NSPhotoLibraryAddUsageDescription", ["UIImageWriteToSavedPhotosAlbum", "UISaveVideoAtPathToSavedPhotosAlbum"]),
        usage("NSLocationWhenInUseUsageDescription", ["requestWhenInUseAuthorization", "CLLocationUpdate", "CLLocationButton"]),
        usage("NSLocationAlwaysAndWhenInUseUsageDescription", ["requestAlwaysAuthorization", "CLServiceSession"]),
        usage("NSContactsUsageDescription", ["CNContactStore"]),
        usage("NSCalendarsFullAccessUsageDescription", ["requestFullAccessToEvents"]),
        usage("NSCalendarsWriteOnlyAccessUsageDescription", ["requestWriteOnlyAccessToEvents"]),
        usage("NSRemindersFullAccessUsageDescription", ["requestFullAccessToReminders"]),
        usage("NSHealthShareUsageDescription", ["HKHealthStore"]),
        usage("NSBluetoothAlwaysUsageDescription", ["CBCentralManager", "CBPeripheralManager"]),
        usage("NSSpeechRecognitionUsageDescription", ["SFSpeechRecognizer"]),
        usage("NSFaceIDUsageDescription", ["LAContext"]),
        usage("NSUserTrackingUsageDescription", ["ATTrackingManager"]),
        usage("NFCReaderUsageDescription", ["NFCNDEFReaderSession", "NFCTagReaderSession"]),
        usage("NSMotionUsageDescription", ["CMMotionActivityManager", "CMPedometer"]),
        usage("NSAppleMusicUsageDescription", ["MPMediaLibrary", "MPMediaQuery"]),
        usage("NSHomeKitUsageDescription", ["HMHomeManager"]),
        usage("NSLocalNetworkUsageDescription", ["NWBrowser", "NetServiceBrowser", "NWListener"]),
    ]

    private static func usage(_ key: String, _ classNames: [String]) -> Rule {
        Rule(target: .usageDescription(key),
             sourceTokens: classNames,
             // ObjC classes are referenced as _OBJC_CLASS_$_Name; selectors appear as plain names.
             binaryTokens: classNames.map { $0.contains(".") ? String($0.split(separator: ".").last!) : "_OBJC_CLASS_$_\($0)" })
    }

    // MARK: - Detection

    /// target → places it was seen.
    public typealias Detections = [Target: [String]]

    public static let sourceExtensions: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp", "h"]

    /// Scans one source file. `//` comments and lines inside `/* */` blocks starting with `*` are skipped.
    public static func scanSource(_ text: String, fileName: String, into detections: inout Detections) {
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = stripTrailingComment(line.trimmingCharacters(in: .whitespaces))
            if trimmed.isEmpty || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            for rule in rules {
                for token in rule.sourceTokens where containsIdentifier(trimmed, token) {
                    let place = "\(fileName):\(number + 1)"
                    if detections[rule.target]?.contains(place) != true {
                        detections[rule.target, default: []].append(place)
                    }
                    break
                }
            }
        }
    }

    /// Scans a compiled binary's bytes for symbol, class and selector names (NUL-delimited).
    public static func scanBinary(_ data: Data, name: String, into detections: inout Detections) {
        for rule in rules {
            for token in rule.binaryTokens {
                var needle = Data([0])
                needle.append(Data(token.utf8))
                needle.append(0)
                // Class refs are prefixed in the string table (e.g. "_OBJC_CLASS_$_X"), so don't require a leading NUL for them.
                let found = token.hasPrefix("_OBJC_CLASS_$_")
                    ? data.range(of: Data(token.utf8) + Data([0])) != nil
                    : data.range(of: needle) != nil
                if found {
                    if detections[rule.target]?.contains(name) != true { detections[rule.target, default: []].append(name) }
                    break
                }
            }
        }
    }

    /// Drops a `//` comment, ignoring `//` inside string literals (e.g. URLs).
    static func stripTrailingComment(_ line: String) -> String {
        var inString = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if c == "\"", previous != "\\" { inString.toggle() }
            if !inString, c == "/", previous == "/" {
                return String(line[..<line.index(before: index)]).trimmingCharacters(in: .whitespaces)
            }
            previous = c
            index = line.index(after: index)
        }
        return line
    }

    /// True when `token` appears in `line` as a whole identifier (not part of a longer name).
    static func containsIdentifier(_ line: String, _ token: String) -> Bool {
        var searchStart = line.startIndex
        while let range = line.range(of: token, range: searchStart..<line.endIndex) {
            let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
            let after = range.upperBound == line.endIndex ? nil : line[range.upperBound]
            let isIdent: (Character?) -> Bool = { c in c.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
            // Only enforce a boundary on sides where the token itself starts/ends with an identifier character.
            let okBefore = !isIdent(token.first) || !isIdent(before)
            let okAfter = !isIdent(token.last) || !isIdent(after)
            if okBefore, okAfter { return true }
            searchStart = range.upperBound
        }
        return false
    }

    // MARK: - Report

    public struct Input: Sendable {
        public var detections: Detections
        /// Manifests found, keyed by where they came from (merged for the check).
        public var manifests: [String: PrivacyManifest]
        /// Info.plist keys, if an Info.plist was found.
        public var infoPlistKeys: [String: PlistValue]?
        /// Text of `project.pbxproj` files, for `INFOPLIST_KEY_*` build settings (generated Info.plists).
        public var buildSettingsText: String

        public init(detections: Detections, manifests: [String: PrivacyManifest], infoPlistKeys: [String: PlistValue]?, buildSettingsText: String = "") {
            self.detections = detections
            self.manifests = manifests
            self.infoPlistKeys = infoPlistKeys
            self.buildSettingsText = buildSettingsText
        }
    }

    public static func report(_ input: Input) -> [PrivacyFinding] {
        var findings: [PrivacyFinding] = []
        let declared = Set(input.manifests.values.flatMap { $0.accessedAPIs.map(\.category) })
        let usedCategories = input.detections.keys.compactMap { target -> RequiredReasonCategory? in
            if case .requiredReason(let c) = target { return c }
            return nil
        }

        if input.manifests.isEmpty, !usedCategories.isEmpty {
            findings.append(.init(severity: .error, title: "No PrivacyInfo.xcprivacy found",
                                  detail: "The code uses required-reason APIs, so App Store Connect requires a privacy manifest declaring why."))
        }

        for category in RequiredReasonCategory.allCases {
            let evidence = input.detections[.requiredReason(category)] ?? []
            if !evidence.isEmpty, !declared.contains(category.rawValue) {
                findings.append(.init(
                    severity: .error,
                    title: "\(category.title) used but not declared",
                    detail: "Add \(category.rawValue) to NSPrivacyAccessedAPITypes with a reason, typically \(category.suggestedReason) (\(category.reasonCodes[category.suggestedReason] ?? "")).",
                    evidence: Array(evidence.prefix(8))
                ))
            } else if evidence.isEmpty, declared.contains(category.rawValue) {
                findings.append(.init(severity: .info, title: "\(category.title) declared but not seen in the scanned code",
                                      detail: "That's fine if a dependency uses them; otherwise the declaration can go."))
            }
        }

        for (path, manifest) in input.manifests.sorted(by: { $0.key < $1.key }) {
            findings += manifest.validate().map { f in
                var f = f
                f.evidence = [path]
                return f
            }
        }

        for (target, evidence) in input.detections {
            guard case .usageDescription(let key) = target else { continue }
            let plistValue = input.infoPlistKeys?[key]?.stringValue
            let inBuildSettings = input.buildSettingsText.contains("INFOPLIST_KEY_\(key)")
            if let plistValue, plistValue.trimmingCharacters(in: .whitespaces).isEmpty {
                findings.append(.init(severity: .error, title: "\(key) is empty",
                                      detail: "App Review rejects empty usage descriptions. Explain why the app needs this permission.", evidence: Array(evidence.prefix(8))))
            } else if plistValue == nil, !inBuildSettings {
                let where_ = input.infoPlistKeys == nil ? "No Info.plist was found and no INFOPLIST_KEY_\(key) build setting either. " : ""
                findings.append(.init(severity: .error, title: "Missing \(key)",
                                      detail: "\(where_)Without it the app crashes when it asks for this permission, and App Review rejects it.",
                                      evidence: Array(evidence.prefix(8))))
            }
        }

        return findings.sorted { ($0.severity, $0.title) < ($1.severity, $1.title) }
    }
}
