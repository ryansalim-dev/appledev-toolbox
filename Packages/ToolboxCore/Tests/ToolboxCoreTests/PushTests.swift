import XCTest
@testable import ToolboxCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A throwaway P-256 key generated for these tests only. It isn't registered with Apple.
let testP8 = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg4oH8KX84J57IZ1ch
XPfnYFY2XrgBVI51pWiHybtf+Y2hRANCAAR9RfB1vFFnFSMP4CP3DWQKK/9S5Gjd
rHv6dR1MoUrorcy72+mfkOIiuOjuIy5jfZKrKvxdTSx4KV1Iq3SSZeIK
-----END PRIVATE KEY-----
"""

final class APNsRequestTests: XCTestCase {
    let token = String(repeating: "ab", count: 32)

    func testURLHeadersAndTopic() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        let request = APNsRequest(
            environment: .production,
            deviceToken: "<\(token.prefix(8)) \(token.dropFirst(8))>",
            bundleID: "com.example.app",
            pushType: .liveactivity,
            payload: "{}",
            expiration: expiry,
            collapseID: "score",
            apnsID: id
        )
        XCTAssertEqual(request.url.absoluteString, "https://api.push.apple.com/3/device/\(token)")
        XCTAssertEqual(request.topic, "com.example.app.push-type.liveactivity")
        XCTAssertEqual(request.headers["apns-push-type"], "liveactivity")
        XCTAssertEqual(request.headers["apns-priority"], "10")
        XCTAssertEqual(request.headers["apns-expiration"], "1800000000")
        XCTAssertEqual(request.headers["apns-collapse-id"], "score")
        XCTAssertEqual(request.headers["apns-id"], "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
        XCTAssertNil(request.headers["authorization"])

        var voip = request
        voip.pushType = .voip
        voip.bundleID = "com.example.app.voip"
        XCTAssertEqual(voip.topic, "com.example.app.voip") // suffix not doubled
        XCTAssertEqual(APNsRequest(deviceToken: token, bundleID: "a.b", payload: "{}").url.host, "api.sandbox.push.apple.com")
    }

    func testValidation() {
        func messages(_ r: APNsRequest) -> [String] { r.validate().map(\.message) }

        let good = APNsRequest(deviceToken: token, bundleID: "com.example.app", payload: #"{"aps":{"alert":"Hi"}}"#)
        XCTAssertEqual(good.validate(), [])

        XCTAssertTrue(messages(APNsRequest(deviceToken: "abc", bundleID: "x", payload: #"{"aps":{"alert":"Hi"}}"#))
            .contains { $0.contains("at least 64 hex") })
        XCTAssertTrue(messages(APNsRequest(deviceToken: token, bundleID: "", payload: #"{"aps":{"alert":"Hi"}}"#))
            .contains { $0.contains("bundle ID") })
        XCTAssertTrue(messages(APNsRequest(deviceToken: token, bundleID: "x", payload: "{nope"))
            .contains("The payload isn't valid JSON."))
        XCTAssertTrue(messages(APNsRequest(deviceToken: token, bundleID: "x", payload: #"{"a":1}"#))
            .contains { $0.contains("\"aps\"") })

        let big = #"{"aps":{"alert":""# + String(repeating: "x", count: 4_100) + #""}}"#
        XCTAssertTrue(messages(APNsRequest(deviceToken: token, bundleID: "x", payload: big)).contains { $0.contains("limit") })

        let background = APNsRequest(deviceToken: token, bundleID: "x", pushType: .background, priority: .immediate, payload: #"{"aps":{"alert":"Hi"}}"#)
        let bg = background.validate()
        XCTAssertTrue(bg.contains { $0.severity == .error && $0.message.contains("content-available") })
        XCTAssertTrue(bg.contains { $0.severity == .warning && $0.message.contains("priority 5") })

        let live = APNsRequest(deviceToken: token, bundleID: "x", pushType: .liveactivity, payload: #"{"aps":{"event":"update"}}"#)
        XCTAssertEqual(live.validate().filter { $0.severity == .error }.count, 2) // timestamp + content-state
    }

    func testTemplatesAreValid() {
        for template in APNsTemplates.all() {
            let request = APNsRequest(deviceToken: token, bundleID: "com.example.app", pushType: template.pushType,
                                      priority: template.priority, payload: template.payload)
            XCTAssertEqual(request.validate().filter { $0.severity == .error }, [], template.name)
        }
    }

    func testResponseParsing() {
        let ok = APNsResponse(statusCode: 200, headers: ["Apns-Id": "abc", "apns-unique-id": "u1"], body: Data())
        XCTAssertTrue(ok.isSuccess)
        XCTAssertEqual(ok.apnsID, "abc")
        XCTAssertEqual(ok.apnsUniqueID, "u1")

        let bad = APNsResponse(statusCode: 400, headers: [:], body: Data(#"{"reason":"BadDeviceToken"}"#.utf8))
        XCTAssertEqual(bad.reason, "BadDeviceToken")
        XCTAssertTrue(bad.explanation.contains("other environment"))

        let gone = APNsResponse(statusCode: 410, headers: [:], body: Data(#"{"reason":"Unregistered","timestamp":1700000000000}"#.utf8))
        XCTAssertEqual(gone.invalidSince, Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(APNsResponse(statusCode: 400, headers: [:], body: Data(#"{"reason":"SomethingNew"}"#.utf8)).explanation,
                       "APNs rejected the push: SomethingNew.")
    }
}

final class APNsTokenTests: XCTestCase {
    func testKeyIDFromFileName() {
        XCTAssertEqual(APNsSigningKey.keyID(fromFileName: "AuthKey_ABC123DEFG.p8"), "ABC123DEFG")
        XCTAssertNil(APNsSigningKey.keyID(fromFileName: "AuthKey_short.p8"))
        XCTAssertNil(APNsSigningKey.keyID(fromFileName: "key.p8"))
    }

    func testRejectsNonPEM() {
        XCTAssertThrowsError(try APNsSigningKey(pem: "hello", keyID: "ABC123DEFG", teamID: "TEAM123456"))
    }

    func testSigningInput() throws {
        let key = try APNsSigningKey(pem: testP8, keyID: "ABC123DEFG", teamID: "TEAM123456")
        let input = key.signingInput(issuedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let parts = input.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(try Base64Tool.decodeToText(parts[0]), #"{"alg":"ES256","kid":"ABC123DEFG"}"#)
        XCTAssertEqual(try Base64Tool.decodeToText(parts[1]), #"{"iss":"TEAM123456","iat":1700000000}"#)
    }

    #if canImport(CryptoKit)
    func testTokenIsVerifiableES256JWT() throws {
        let key = try APNsSigningKey(pem: testP8, keyID: "ABC123DEFG", teamID: "TEAM123456")
        let token = try key.makeToken(issuedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)

        let jwt = try JWTDecoder.decode(token)
        XCTAssertEqual(jwt.algorithm, "ES256")
        XCTAssertEqual(jwt.keyID, "ABC123DEFG")
        XCTAssertEqual(jwt.issuer, "TEAM123456")

        let publicKey = try P256.Signing.PrivateKey(pemRepresentation: testP8).publicKey
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Base64Tool.decode(parts[2]))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    func testTokenCacheReusesFor50Minutes() throws {
        let key = try APNsSigningKey(pem: testP8, keyID: "ABC123DEFG", teamID: "TEAM123456")
        var cache = APNsTokenCache()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try cache.token(for: key, now: start)
        XCTAssertEqual(try cache.token(for: key, now: start.addingTimeInterval(49 * 60)), first)
        XCTAssertNotEqual(try cache.token(for: key, now: start.addingTimeInterval(51 * 60)), first)
    }
    #endif
}

final class SimulatorPushTests: XCTestCase {
    func testParsesSimctlDevices() {
        let json = """
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-1" : [
              { "udid" : "AAAA-1111", "name" : "iPhone 16 Pro", "state" : "Booted", "isAvailable" : true },
              { "udid" : "BBBB-2222", "name" : "iPad Air", "state" : "Shutdown", "isAvailable" : true },
              { "udid" : "CCCC-3333", "name" : "Broken", "state" : "Shutdown", "isAvailable" : false }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-0" : []
          }
        }
        """
        let devices = SimulatorPush.parseDevices(json)
        XCTAssertEqual(devices.map(\.name), ["iPad Air", "iPhone 16 Pro"])
        XCTAssertEqual(devices.first(where: \.isBooted)?.udid, "AAAA-1111")
        XCTAssertEqual(devices.first?.runtime, "iOS 18.1")
        XCTAssertEqual(SimulatorPush.parseDevices("garbage"), [])
        XCTAssertEqual(SimulatorPush.pushArguments(deviceUDID: "AAAA", bundleID: "com.x", payloadPath: "/tmp/p.json"),
                       ["simctl", "push", "AAAA", "com.x", "/tmp/p.json"])
    }
}
