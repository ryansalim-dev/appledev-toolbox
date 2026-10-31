import XCTest
@testable import ToolboxCore

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

final class ProvisioningProfileTests: XCTestCase {
    func testParsesDevelopmentProfile() throws {
        let profile = try ProvisioningProfile.parse(fixture("development.mobileprovision"))
        XCTAssertEqual(profile.name, "iOS Team Provisioning Profile: com.example.app")
        XCTAssertEqual(profile.uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(profile.teamName, "Example Team")
        XCTAssertEqual(profile.teamIdentifiers, ["ABCDE12345"])
        XCTAssertEqual(profile.kind, .development)
        XCTAssertEqual(profile.bundleIdentifier, "com.example.app")
        XCTAssertEqual(profile.provisionedDevices.count, 1)
        XCTAssertEqual(profile.developerCertificates.count, 1)
        XCTAssertEqual(profile.entitlements["get-task-allow"], .bool(true))
        XCTAssertEqual(profile.entitlements["keychain-access-groups"], .array([.string("ABCDE12345.*")]))
        XCTAssertEqual(profile.entitlements["aps-environment"], .string("development"))
        XCTAssertTrue(profile.isExpired(at: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testKinds() throws {
        XCTAssertEqual(try ProvisioningProfile.parse(fixture("appstore.mobileprovision")).kind, .appStore)
    }

    func testRejectsNonProfile() {
        XCTAssertThrowsError(try ProvisioningProfile.parse(Data("hello".utf8)))
    }

    func testLibraryLoadsAndFindsSuperseded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try fixture("development.mobileprovision").write(to: dir.appendingPathComponent("a.mobileprovision"))
        try fixture("appstore.mobileprovision").write(to: dir.appendingPathComponent("b.mobileprovision"))
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("c.mobileprovision"))
        try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let library = ProfileLibrary.load(from: [dir, dir.appendingPathComponent("missing")])
        XCTAssertEqual(library.profiles.count, 2)
        XCTAssertEqual(library.failures.map(\.lastPathComponent), ["c.mobileprovision"])
        XCTAssertEqual(library.profiles.first?.kind, .development) // sorted by expiry
        XCTAssertEqual(library.expired(at: Date(timeIntervalSince1970: 1_770_000_000)).count, 1)
        XCTAssertTrue(library.superseded().isEmpty) // different kinds, nothing superseded
    }
}

final class CrashReportTests: XCTestCase {
    func testParsesIPS() throws {
        let report = try CrashReportParser.parse(fixture("crash.ips"))
        XCTAssertTrue(report.isCrash)
        XCTAssertEqual(report.appName, "MyApp")
        XCTAssertEqual(report.bundleID, "com.example.app")
        XCTAssertEqual(report.appVersion, "2.3.0")
        XCTAssertEqual(report.buildVersion, "145")
        XCTAssertEqual(report.osVersion, "iPhone OS 18.1 (22B83)")
        XCTAssertEqual(report.hardwareModel, "iPhone16,1")
        XCTAssertEqual(report.pid, 4242)
        XCTAssertEqual(report.exception?.type, "EXC_BREAKPOINT")
        XCTAssertEqual(report.exception?.signal, "SIGTRAP")
        XCTAssertEqual(report.termination?.indicator, "Trace/BPT trap: 5")
        XCTAssertEqual(report.threads.count, 2)
        XCTAssertEqual(report.crashedThread?.index, 0)
        XCTAssertEqual(report.crashedThread?.queue, "com.apple.main-thread")
        XCTAssertEqual(report.images.count, 2)
        XCTAssertEqual(report.images[0].normalizedUUID, "0B7A2A7C-1C0E-3F5E-9D1E-6A2A4A8C0F11")
        XCTAssertEqual(report.applicationMessages.first?.contains("Unexpectedly found nil"), true)
        XCTAssertEqual(report.threads[0].frames[0].address(in: report.images), 4_300_000_000 + 16_960)
        // Unknown future fields are kept in the raw body.
        XCTAssertNotNil(report.rawBody?["someFutureField"])
    }

    func testFormatterAndSymbolication() throws {
        let report = try CrashReportParser.parse(fixture("crash.ips"))

        let requests = Symbolication.requests(for: report)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].image.name, "MyApp")
        XCTAssertEqual(requests[0].addresses, [4_300_016_960, 4_300_017_204])

        let args = Symbolication.atosArguments(for: requests[0], binaryPath: "/tmp/MyApp.dSYM/Contents/Resources/DWARF/MyApp")
        XCTAssertEqual(args, ["atos", "-arch", "arm64", "-o", "/tmp/MyApp.dSYM/Contents/Resources/DWARF/MyApp",
                              "-l", "0x" + String(4_300_000_000, radix: 16),
                              "0x" + String(4_300_016_960, radix: 16), "0x" + String(4_300_017_204, radix: 16)])

        let atosOutput = """
        ProfileViewModel.load() (in MyApp) (ProfileViewModel.swift:88)
        0x1004d4334
        """
        let resolved = Symbolication.parseAtosOutput(atosOutput, addresses: requests[0].addresses)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[4_300_016_960], ResolvedSymbol(symbol: "ProfileViewModel.load()", sourceFile: "ProfileViewModel.swift", sourceLine: 88))

        let text = CrashReportFormatter.text(for: report, resolved: resolved)
        XCTAssertTrue(text.contains("Exception Type:     EXC_BREAKPOINT (SIGTRAP)"))
        XCTAssertTrue(text.contains("Thread 0 Crashed::  Dispatch queue: com.apple.main-thread"))
        XCTAssertTrue(text.contains("ProfileViewModel.load() (ProfileViewModel.swift:88)"))
        XCTAssertTrue(text.contains("-[UIApplication _run] + 888"))
        XCTAssertTrue(text.contains("main + 120 (MyApp.swift:12)"))
        XCTAssertTrue(text.contains("Thread 1:: com.apple.uikit.eventfetch-thread"))
        XCTAssertTrue(text.contains("Binary Images:"))
        XCTAssertTrue(text.contains("<0b7a2a7c1c0e3f5e9d1e6a2a4a8c0f11>"))
    }

    func testAtosLineVariants() {
        XCTAssertEqual(Symbolication.parseAtosLine("foo (in MyApp) + 40"), ResolvedSymbol(symbol: "foo"))
        XCTAssertEqual(Symbolication.parseAtosLine("closure #1 in View.body.getter (in MyApp) (View.swift:7)"),
                       ResolvedSymbol(symbol: "closure #1 in View.body.getter", sourceFile: "View.swift", sourceLine: 7))
    }

    func testDwarfdumpParsing() {
        let output = """
        UUID: 0B7A2A7C-1C0E-3F5E-9D1E-6A2A4A8C0F11 (arm64) /Builds/MyApp.app.dSYM/Contents/Resources/DWARF/MyApp
        UUID: 11111111-1C0E-3F5E-9D1E-6A2A4A8C0F11 (x86_64) /Builds/MyApp.app.dSYM/Contents/Resources/DWARF/MyApp
        """
        let entries = Symbolication.parseDwarfdumpUUIDs(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].arch, "arm64")
        XCTAssertEqual(entries[0].path, "/Builds/MyApp.app.dSYM/Contents/Resources/DWARF/MyApp")
        XCTAssertEqual(Symbolication.spotlightQuery(forUUID: "0b7a2a7c1c0e3f5e9d1e6a2a4a8c0f11"),
                       "com_apple_xcode_dsym_uuids == 0B7A2A7C-1C0E-3F5E-9D1E-6A2A4A8C0F11")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try CrashReportParser.parse(""))
        XCTAssertThrowsError(try CrashReportParser.parse("not json\n{}"))
    }
}

final class InputDetectorTests: XCTestCase {
    func testDetectsText() throws {
        XCTAssertEqual(InputDetector.detect(text: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig"), .jwt)
        XCTAssertEqual(InputDetector.detect(text: #"  {"a": 1}  "#), .json)
        XCTAssertEqual(InputDetector.detect(text: "[1,2]"), .json)
        XCTAssertEqual(InputDetector.detect(text: "1700000000"), .unixTimestamp)
        XCTAssertEqual(InputDetector.detect(text: "1700000000123"), .unixTimestamp)
        XCTAssertEqual(InputDetector.detect(text: "SGVsbG8gV29ybGQh"), .base64)
        XCTAssertEqual(InputDetector.detect(text: "hello world"), .unknown)
        XCTAssertEqual(InputDetector.detect(text: "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>"), .propertyList)
        XCTAssertEqual(InputDetector.detect(text: String(decoding: try fixture("crash.ips"), as: UTF8.self)), .crashLog)
    }

    func testDetectsFiles() throws {
        XCTAssertEqual(InputDetector.detect(fileExtension: "mobileprovision", data: Data()), .provisioningProfile)
        XCTAssertEqual(InputDetector.detect(fileExtension: "IPS", data: Data()), .crashLog)
        XCTAssertEqual(InputDetector.detect(fileExtension: "xcprivacy", data: Data()), .propertyList)
        XCTAssertEqual(InputDetector.detect(fileExtension: "bin", data: try fixture("development.mobileprovision")), .provisioningProfile)
        XCTAssertEqual(InputDetector.detect(fileExtension: "txt", data: Data(#"{"a":1}"#.utf8)), .json)
        XCTAssertEqual(InputDetector.detect(fileExtension: "", data: Data("bplist00".utf8)), .propertyList)
    }
}
