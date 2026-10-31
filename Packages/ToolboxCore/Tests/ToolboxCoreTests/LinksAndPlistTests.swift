import XCTest
@testable import ToolboxCore

final class AASATests: XCTestCase {
    let sample = """
    {
      "applinks": {
        "defaults": { "caseSensitive": false },
        "details": [
          {
            "appIDs": ["ABCDE12345.com.example.app", "ABCDE12345.com.example.app.beta"],
            "components": [
              { "/": "/account/*", "exclude": true, "comment": "Keep account pages in Safari" },
              { "/": "/buy/?*", "?": { "ref": "?*" } },
              { "/": "/promo/*", "#": "no_universal_links", "exclude": true },
              { "/": "/promo/*" },
              { "/": "/legacy" , "caseSensitive": true }
            ]
          },
          {
            "appIDs": ["ABCDE12345.com.example.clip"],
            "paths": ["NOT /old/private/*", "/old/*"]
          }
        ]
      },
      "webcredentials": { "apps": ["ABCDE12345.com.example.app"] },
      "appclips": { "apps": ["ABCDE12345.com.example.app.Clip"] }
    }
    """

    func testParsesAndValidates() throws {
        let (file, issues) = try AASAFile.parse(Data(sample.utf8))
        XCTAssertEqual(file.details.count, 2)
        XCTAssertEqual(file.details[0].appIDs.count, 2)
        XCTAssertEqual(file.details[0].components.count, 5)
        XCTAssertEqual(file.details[0].components[1].query, .items(["ref": "?*"]))
        XCTAssertFalse(file.defaultCaseSensitive)
        XCTAssertEqual(file.webCredentialsApps, ["ABCDE12345.com.example.app"])
        XCTAssertEqual(issues.map(\.severity), [.warning]) // only the legacy-paths warning
        XCTAssertTrue(issues[0].message.contains("legacy"))
    }

    func testValidationErrors() throws {
        let bad = #"{"applinks":{"details":[{"appIDs":["com.example.app"],"components":[{"/":"buy"}]}]}}"#
        let issues = try AASAFile.parse(Data(bad.utf8)).issues
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("valid app ID") })
        XCTAssertTrue(issues.contains { $0.severity == .warning && $0.message.contains("should start with") })

        XCTAssertTrue(try AASAFile.parse(Data("{}".utf8)).issues.contains { $0.message.contains("no applinks") })
        XCTAssertThrowsError(try AASAFile.parse(Data("[1]".utf8)))
        XCTAssertThrowsError(try AASAFile.parse(Data("<html>".utf8)))
    }

    func testMatching() throws {
        let file = try AASAFile.parse(Data(sample.utf8)).file
        func outcome(_ s: String, detail: Int = 0) -> AASAFile.Match.Outcome { file.match(URL(string: s)!)[detail].outcome }

        XCTAssertEqual(outcome("https://example.com/account/settings"), .excluded)
        XCTAssertEqual(outcome("https://example.com/ACCOUNT/x"), .excluded)          // defaults: case-insensitive
        XCTAssertEqual(outcome("https://example.com/buy/123?ref=mail"), .opensApp)
        XCTAssertEqual(outcome("https://example.com/buy/123"), .noMatch)               // ref is required (?*)
        XCTAssertEqual(outcome("https://example.com/buy/?ref=mail"), .noMatch)         // ?* needs at least one char
        XCTAssertEqual(outcome("https://example.com/promo/fall#no_universal_links"), .excluded)
        XCTAssertEqual(outcome("https://example.com/promo/fall"), .opensApp)
        XCTAssertEqual(outcome("https://example.com/legacy"), .opensApp)
        XCTAssertEqual(outcome("https://example.com/LEGACY"), .noMatch)                // component overrides to case-sensitive
        XCTAssertEqual(outcome("https://example.com/"), .noMatch)

        XCTAssertEqual(outcome("https://example.com/old/page", detail: 1), .opensApp)
        XCTAssertEqual(outcome("https://example.com/old/private/x", detail: 1), .excluded)

        let match = file.match(URL(string: "https://example.com/account/a")!)[0]
        XCTAssertEqual(match.rule, #""/": "/account/*", exclude (Keep account pages in Safari)"#)
    }

    func testWildcards() {
        XCTAssertTrue(AASAFile.wildcardMatch(pattern: "/a/*", text: "/a/", caseSensitive: true))
        XCTAssertTrue(AASAFile.wildcardMatch(pattern: "*", text: "", caseSensitive: true))
        XCTAssertTrue(AASAFile.wildcardMatch(pattern: "/p/???", text: "/p/abc", caseSensitive: true))
        XCTAssertFalse(AASAFile.wildcardMatch(pattern: "/p/???", text: "/p/ab", caseSensitive: true))
        XCTAssertTrue(AASAFile.wildcardMatch(pattern: "/*/x/*", text: "/a/b/x/c", caseSensitive: true))
        XCTAssertFalse(AASAFile.wildcardMatch(pattern: "/A", text: "/a", caseSensitive: true))
        XCTAssertTrue(AASAFile.wildcardMatch(pattern: "/A", text: "/a", caseSensitive: false))
    }

    func testDomainAndHTTPChecks() {
        XCTAssertEqual(AASAFetch.normalizeDomain("applinks:Example.com?mode=developer"), "example.com")
        XCTAssertEqual(AASAFetch.normalizeDomain("https://www.example.com/some/path"), "www.example.com")
        XCTAssertEqual(AASAFetch.normalizeDomain("example.com"), "example.com")
        XCTAssertNil(AASAFetch.normalizeDomain("localhost"))
        XCTAssertEqual(AASAFetch.cdnURL(for: "example.com").absoluteString, "https://app-site-association.cdn-apple.com/a/v1/example.com")

        let url = AASAFetch.directURL(for: "example.com")
        XCTAssertEqual(AASAFetch.checkResponse(requested: url, final: url, statusCode: 200, contentType: "application/json; charset=utf-8", byteCount: 500), [])
        let issues = AASAFetch.checkResponse(requested: url, final: URL(string: "https://www.example.com/.well-known/apple-app-site-association"),
                                             statusCode: 404, contentType: "text/html", byteCount: 200_000)
        XCTAssertEqual(issues.filter { $0.severity == .error }.count, 3)
        XCTAssertEqual(issues.filter { $0.severity == .warning }.count, 1)
    }
}

final class PlistTests: XCTestCase {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>CFBundleIdentifier</key>
    \t<string>com.example.app</string>
    \t<key>UIRequiredDeviceCapabilities</key>
    \t<array>
    \t\t<string>arm64</string>
    \t</array>
    \t<key>LSRequiresIPhoneOS</key>
    \t<true/>
    \t<key>BuildNumber</key>
    \t<integer>1</integer>
    \t<key>Scale</key>
    \t<real>2.5</real>
    \t<key>Blob</key>
    \t<data>AAEC</data>
    \t<key>Nested</key>
    \t<dict>
    \t\t<key>Escaped</key>
    \t\t<string>a &amp; b &lt;c&gt;</string>
    \t</dict>
    </dict>
    </plist>
    """

    func testParsesAndKeepsTypes() throws {
        let doc = try PlistDocument.parse(Data(xml.utf8))
        XCTAssertEqual(doc.format, .xml)
        guard case .dictionary(let root) = doc.root else { return XCTFail("root should be a dictionary") }
        XCTAssertEqual(root["LSRequiresIPhoneOS"], .bool(true))
        XCTAssertEqual(root["BuildNumber"], .integer(1))
        XCTAssertEqual(root["Scale"], .real(2.5))
        XCTAssertEqual(root["Blob"], .data(Data([0, 1, 2])))
        XCTAssertEqual(root["Nested"]?.dictionaryValue?["Escaped"], .string("a & b <c>"))
    }

    func testXMLRoundTrip() throws {
        let doc = try PlistDocument.parse(Data(xml.utf8))
        let again = try PlistDocument.parse(Data(doc.xmlString().utf8))
        XCTAssertEqual(again.root, doc.root)
        XCTAssertTrue(doc.xmlString().contains("<string>a &amp; b &lt;c&gt;</string>"))
    }

    func testNodesAndJSON() throws {
        let doc = try PlistDocument.parse(Data(xml.utf8))
        XCTAssertEqual(doc.nodes.map(\.key), ["Blob", "BuildNumber", "CFBundleIdentifier", "LSRequiresIPhoneOS", "Nested", "Scale", "UIRequiredDeviceCapabilities"])
        let caps = try XCTUnwrap(doc.nodes.first { $0.key == "UIRequiredDeviceCapabilities" })
        XCTAssertEqual(caps.type, "Array")
        XCTAssertEqual(caps.value, "1 item")
        XCTAssertEqual(caps.children?.first?.id, "UIRequiredDeviceCapabilities[0]")
        XCTAssertEqual(doc.nodes.first { $0.key == "Nested" }?.children?.first?.id, "Nested.Escaped")

        XCTAssertEqual(doc.jsonValue()["Blob"], .string("AAEC"))
        XCTAssertEqual(doc.jsonValue()["LSRequiresIPhoneOS"], .bool(true))
    }

    func testDiff() {
        let old: PlistValue = .dictionary([
            "get-task-allow": .bool(true),
            "aps-environment": .string("development"),
            "com.apple.developer.associated-domains": .array([.string("applinks:a.com"), .string("applinks:b.com")]),
            "removed-key": .string("x"),
        ])
        let new: PlistValue = .dictionary([
            "get-task-allow": .bool(false),
            "aps-environment": .string("development"),
            "com.apple.developer.associated-domains": .array([.string("applinks:b.com"), .string("applinks:c.com")]),
            "added-key": .integer(3),
        ])
        let changes = PlistDiff.compare(old, new)
        XCTAssertEqual(changes, [
            .init(kind: .added, path: "added-key", old: nil, new: "3"),
            .init(kind: .removed, path: "com.apple.developer.associated-domains", old: "applinks:a.com", new: nil),
            .init(kind: .added, path: "com.apple.developer.associated-domains", old: nil, new: "applinks:c.com"),
            .init(kind: .changed, path: "get-task-allow", old: "YES", new: "NO"),
            .init(kind: .removed, path: "removed-key", old: "x", new: nil),
        ])
        XCTAssertEqual(PlistDiff.compare(old, old), [])
    }

    func testAppBundleHelpers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Payload/My.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: app.appendingPathComponent("embedded.mobileprovision"))

        XCTAssertEqual(AppBundleFiles.appInUnzippedIPA(root)?.lastPathComponent, "My.app")
        XCTAssertEqual(AppBundleFiles.infoPlistURL(inApp: app).lastPathComponent, "Info.plist")
        XCTAssertEqual(AppBundleFiles.embeddedProfileURL(inApp: app)?.lastPathComponent, "embedded.mobileprovision")
        XCTAssertNil(AppBundleFiles.privacyManifestURL(inApp: app))
        XCTAssertEqual(AppBundleFiles.codesignEntitlementsArguments(path: "/x.app"), ["-d", "--entitlements", "-", "--xml", "/x.app"])
    }
}
