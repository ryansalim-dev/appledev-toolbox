import XCTest
@testable import ToolboxCore

final class PrivacyManifestTests: XCTestCase {
    let manifestXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
    \t<key>NSPrivacyTracking</key><false/>
    \t<key>NSPrivacyTrackingDomains</key><array/>
    \t<key>NSPrivacyCollectedDataTypes</key>
    \t<array>
    \t\t<dict>
    \t\t\t<key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeEmailAddress</string>
    \t\t\t<key>NSPrivacyCollectedDataTypeLinked</key><true/>
    \t\t\t<key>NSPrivacyCollectedDataTypeTracking</key><false/>
    \t\t\t<key>NSPrivacyCollectedDataTypePurposes</key><array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    \t\t</dict>
    \t</array>
    \t<key>NSPrivacyAccessedAPITypes</key>
    \t<array>
    \t\t<dict>
    \t\t\t<key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string>
    \t\t\t<key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array>
    \t\t</dict>
    \t</array>
    </dict>
    </plist>
    """

    func testParsesValidManifest() throws {
        let manifest = try PrivacyManifest.parse(Data(manifestXML.utf8))
        XCTAssertEqual(manifest.tracking, false)
        XCTAssertEqual(manifest.accessedAPIs, [.init(category: "NSPrivacyAccessedAPICategoryUserDefaults", reasons: ["CA92.1"])])
        XCTAssertEqual(manifest.collectedDataTypes.first?.type, "NSPrivacyCollectedDataTypeEmailAddress")
        XCTAssertEqual(manifest.validate(), [])
    }

    func testValidationCatchesBadReasonsAndIncompleteEntries() {
        let manifest = PrivacyManifest(
            tracking: false,
            trackingDomains: ["tracker.example.com"],
            collectedDataTypes: [.init(type: "NSPrivacyCollectedDataTypeName", linked: nil, tracking: false, purposes: [])],
            accessedAPIs: [
                .init(category: "NSPrivacyAccessedAPICategoryDiskSpace", reasons: ["CA92.1"]),
                .init(category: "NSPrivacyAccessedAPICategorySystemBootTime", reasons: []),
                .init(category: "NSPrivacyAccessedAPICategoryMadeUp", reasons: ["X"]),
            ]
        )
        let titles = manifest.validate().map(\.title)
        XCTAssertTrue(titles.contains("Disk space APIs: \"CA92.1\" isn't a valid reason"))
        XCTAssertTrue(titles.contains("System boot time APIs: no reason given"))
        XCTAssertTrue(titles.contains("Unknown API category \"NSPrivacyAccessedAPICategoryMadeUp\""))
        XCTAssertTrue(titles.contains("Tracking domains listed while NSPrivacyTracking is false"))
        XCTAssertTrue(titles.contains("Collected data type NSPrivacyCollectedDataTypeName is incomplete"))
    }
}

final class PrivacyScannerTests: XCTestCase {
    let source = """
    import SwiftUI
    import AVFoundation

    struct Settings {
        @AppStorage("theme") var theme = "dark"
        var creationDate: Date            // a model property, not a file API
        // UserDefaults in a comment doesn't count
        func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        func free() throws -> Int64? {
            try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        }
        func camera() { AVCaptureDevice.requestAccess(for: .video) { _ in } }
        let myUserDefaultsWrapper = 1     // not the UserDefaults identifier
    }
    """

    func testSourceDetection() {
        var detections = PrivacyScanner.Detections()
        PrivacyScanner.scanSource(source, fileName: "Settings.swift", into: &detections)
        XCTAssertEqual(detections[.requiredReason(.userDefaults)], ["Settings.swift:5"])
        XCTAssertEqual(detections[.requiredReason(.systemBootTime)], ["Settings.swift:8"])
        XCTAssertEqual(detections[.requiredReason(.diskSpace)], ["Settings.swift:10"])
        XCTAssertEqual(detections[.usageDescription("NSCameraUsageDescription")], ["Settings.swift:12"])
        XCTAssertNil(detections[.requiredReason(.fileTimestamp)])
    }

    func testBinaryDetection() {
        var bytes = Data("garbage".utf8)
        for s in ["_mach_absolute_time", "_OBJC_CLASS_$_NSUserDefaults", "systemUptimeX", "_OBJC_CLASS_$_CLLocationManager"] {
            bytes.append(0); bytes.append(Data(s.utf8))
        }
        bytes.append(0)
        var detections = PrivacyScanner.Detections()
        PrivacyScanner.scanBinary(bytes, name: "MyApp", into: &detections)
        XCTAssertEqual(detections[.requiredReason(.systemBootTime)], ["MyApp"])
        XCTAssertEqual(detections[.requiredReason(.userDefaults)], ["MyApp"])
        XCTAssertNil(detections[.requiredReason(.diskSpace)])
    }

    func testIdentifierBoundaries() {
        XCTAssertTrue(PrivacyScanner.containsIdentifier("let d = UserDefaults.standard", "UserDefaults"))
        XCTAssertFalse(PrivacyScanner.containsIdentifier("let d = MyUserDefaults()", "UserDefaults"))
        XCTAssertFalse(PrivacyScanner.containsIdentifier("let d = UserDefaultsKeys", "UserDefaults"))
        XCTAssertTrue(PrivacyScanner.containsIdentifier("attrs[.creationDate]", "[.creationDate]"))
    }

    func testReport() {
        var detections = PrivacyScanner.Detections()
        PrivacyScanner.scanSource(source, fileName: "Settings.swift", into: &detections)
        let manifest = PrivacyManifest(tracking: false, accessedAPIs: [
            .init(category: RequiredReasonCategory.userDefaults.rawValue, reasons: ["CA92.1"]),
            .init(category: RequiredReasonCategory.activeKeyboards.rawValue, reasons: ["54BD.1"]),
        ])

        let findings = PrivacyScanner.report(.init(
            detections: detections,
            manifests: ["PrivacyInfo.xcprivacy": manifest],
            infoPlistKeys: ["CFBundleName": .string("X")]
        ))
        let titles = findings.map(\.title)
        XCTAssertTrue(titles.contains("System boot time APIs used but not declared"))
        XCTAssertTrue(titles.contains("Disk space APIs used but not declared"))
        XCTAssertFalse(titles.contains { $0.hasPrefix("User defaults APIs used") })
        XCTAssertTrue(titles.contains("Active keyboard APIs declared but not seen in the scanned code"))
        XCTAssertTrue(titles.contains("Missing NSCameraUsageDescription"))
        XCTAssertEqual(findings.first?.severity, .error)  // sorted errors first
        XCTAssertEqual(findings.last?.severity, .info)

        // A generated Info.plist key in build settings satisfies the usage description.
        let withBuildSetting = PrivacyScanner.report(.init(
            detections: [.usageDescription("NSCameraUsageDescription"): ["A.swift:1"]],
            manifests: [:], infoPlistKeys: nil,
            buildSettingsText: "INFOPLIST_KEY_NSCameraUsageDescription = \"Scan receipts\";"
        ))
        XCTAssertEqual(withBuildSetting, [])

        let empty = PrivacyScanner.report(.init(
            detections: [.usageDescription("NSCameraUsageDescription"): ["A.swift:1"]],
            manifests: [:], infoPlistKeys: ["NSCameraUsageDescription": .string(" ")]
        ))
        XCTAssertEqual(empty.map(\.title), ["NSCameraUsageDescription is empty"])

        let noManifest = PrivacyScanner.report(.init(detections: [.requiredReason(.userDefaults): ["A.swift:1"]], manifests: [:], infoPlistKeys: nil))
        XCTAssertTrue(noManifest.map(\.title).contains("No PrivacyInfo.xcprivacy found"))
    }
}

final class AppIconSetTests: XCTestCase {
    func testIOSWithVariants() throws {
        let plan = AppIconSet.plan(platforms: [.iOS], variants: [.dark, .tinted])
        XCTAssertEqual(plan.renditions.map(\.filename), ["AppIcon-iOS-1024.png", "AppIcon-iOS-1024-dark.png", "AppIcon-iOS-1024-tinted.png"])
        XCTAssertEqual(plan.renditions.map(\.opaque), [true, false, true])

        let json = try JSONParser.parse(plan.contentsJSON)
        let images = try XCTUnwrap(json["images"]?.arrayValue)
        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(images[0]["platform"], .string("ios"))
        XCTAssertNil(images[0]["appearances"])
        XCTAssertEqual(images[1]["appearances"]?[0]?["value"], .string("dark"))
        XCTAssertEqual(json["info"]?["author"], .string("xcode"))
    }

    func testMacAndWatch() throws {
        let plan = AppIconSet.plan(platforms: [.macOS, .watchOS])
        XCTAssertEqual(plan.renditions.count, 11)
        XCTAssertEqual(Set(plan.renditions.filter { $0.filename.contains("mac") }.map(\.pixels)), [16, 32, 64, 128, 256, 512, 1024])
        let images = try XCTUnwrap(JSONParser.parse(plan.contentsJSON)["images"]?.arrayValue)
        XCTAssertEqual(images.filter { $0["idiom"] == .string("mac") }.count, 10)
        XCTAssertEqual(images.last?["platform"], .string("watchos"))
    }

    func testSourceValidation() {
        XCTAssertEqual(AppIconSet.validateSource(width: 1024, height: 1024, hasAlpha: false, platforms: [.iOS]), [])
        let issues = AppIconSet.validateSource(width: 800, height: 600, hasAlpha: true, platforms: [.iOS])
        XCTAssertEqual(issues.filter { $0.severity == .error }.count, 2)
        XCTAssertEqual(issues.filter { $0.severity == .warning }.count, 1)
        XCTAssertEqual(AppIconSet.validateSource(width: 1024, height: 1024, hasAlpha: true, platforms: [.macOS]), [])
        XCTAssertEqual(AppIconSet.validateSource(width: 1024, height: 1024, hasAlpha: true, platforms: [.iOS], variant: .dark), [])
    }
}

final class CommentStrippingTests: XCTestCase {
    func testStripsTrailingCommentsButNotURLs() {
        XCTAssertEqual(PrivacyScanner.stripTrailingComment("let a = 1 // UserDefaults"), "let a = 1")
        XCTAssertEqual(PrivacyScanner.stripTrailingComment(#"let u = "https://example.com" // note"#), #"let u = "https://example.com""#)
        XCTAssertEqual(PrivacyScanner.stripTrailingComment("// whole line"), "")
    }
}
