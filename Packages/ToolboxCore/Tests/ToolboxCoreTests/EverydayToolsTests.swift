import XCTest
@testable import ToolboxCore

final class JSONTests: XCTestCase {
    func testParsePreservesKeyOrder() throws {
        let value = try JSONParser.parse(#"{"zeta": 1, "alpha": [true, null, "x"], "mid": {"b": 2.5, "a": -1e3}}"#)
        XCTAssertEqual(value.objectValue?.map(\.key), ["zeta", "alpha", "mid"])
        XCTAssertEqual(value["mid"]?["a"], .number("-1e3"))
    }

    func testFormattedAndMinifiedRoundTrip() throws {
        let source = #"{"b":1,"a":{"list":[1,2],"empty":{},"none":[]},"s":"line\nbreak \"quoted\" é"}"#
        let value = try JSONParser.parse(source)
        XCTAssertEqual(value.minified(), source)
        XCTAssertEqual(try JSONParser.parse(value.formatted()), value)
        XCTAssertEqual(value.formatted(), """
        {
          "b": 1,
          "a": {
            "list": [
              1,
              2
            ],
            "empty": {},
            "none": []
          },
          "s": "line\\nbreak \\"quoted\\" é"
        }
        """)
    }

    func testSortKeys() throws {
        XCTAssertEqual(try JSONParser.parse(#"{"b":1,"a":2}"#).minified(sortKeys: true), #"{"a":2,"b":1}"#)
    }

    func testUnicodeEscapesAndSurrogatePairs() throws {
        XCTAssertEqual(try JSONParser.parse(#""café 😀""#), .string("café 😀"))
    }

    func testErrorsReportLineAndColumn() {
        XCTAssertThrowsError(try JSONParser.parse("{\n  \"a\": 1,\n  \"b\": tru\n}")) { error in
            let e = error as! JSONParseError
            XCTAssertEqual(e.line, 3)
            XCTAssertEqual(e.column, 8)
        }
        XCTAssertThrowsError(try JSONParser.parse("[1, 2,]"))
        XCTAssertThrowsError(try JSONParser.parse("01"))
        XCTAssertThrowsError(try JSONParser.parse("{\"a\":1} x"))
        XCTAssertThrowsError(try JSONParser.parse("\"unterminated"))
    }
}

final class CodableGeneratorTests: XCTestCase {
    func testGeneratesNestedStructsWithCodingKeys() throws {
        let json = """
        {
          "id": 42,
          "user_name": "ryan",
          "score": 9.5,
          "is_active": true,
          "avatar_url": null,
          "profile": { "bio": "hi", "follower_count": 10 },
          "tags": ["a", "b"],
          "posts": [
            { "id": 1, "title": "First", "likes": 3 },
            { "id": 2, "title": "Second", "likes": 4.5, "pinned": true }
          ]
        }
        """
        let output = try CodableGenerator.generate(from: json)
        XCTAssertEqual(output, """
        struct Root: Codable {
            let id: Int
            let userName: String
            let score: Double
            let isActive: Bool
            let avatarUrl: String? // TODO: only null in sample, check the real type
            let profile: Profile
            let tags: [String]
            let posts: [Post]

            enum CodingKeys: String, CodingKey {
                case id
                case userName = "user_name"
                case score
                case isActive = "is_active"
                case avatarUrl = "avatar_url"
                case profile
                case tags
                case posts
            }
        }

        struct Profile: Codable {
            let bio: String
            let followerCount: Int

            enum CodingKeys: String, CodingKey {
                case bio
                case followerCount = "follower_count"
            }
        }

        struct Post: Codable {
            let id: Int
            let title: String
            let likes: Double
            let pinned: Bool?
        }

        """)
    }

    func testArrayRootAndOptions() throws {
        let output = try CodableGenerator.generate(
            from: #"[{"default": 1, "Type": "x"}]"#,
            options: .init(rootName: "item", conformances: ["Codable", "Hashable"], useVar: true)
        )
        XCTAssertTrue(output.hasPrefix("// Decode with: try JSONDecoder().decode([Item].self, from: data)"))
        XCTAssertTrue(output.contains("struct Item: Codable, Hashable {"))
        XCTAssertTrue(output.contains("    var `default`: Int"))
        XCTAssertTrue(output.contains("        case `default`\n"))
        XCTAssertTrue(output.contains(#"        case type = "Type""#))
    }

    func testRejectsPrimitiveRoot() {
        XCTAssertThrowsError(try CodableGenerator.generate(from: "42"))
    }

    func testNaming() {
        XCTAssertEqual(CodableGenerator.propertyName(for: "user_id"), "userId")
        XCTAssertEqual(CodableGenerator.propertyName(for: "URL"), "url")
        XCTAssertEqual(CodableGenerator.propertyName(for: "createdAt"), "createdAt")
        XCTAssertEqual(CodableGenerator.propertyName(for: "kebab-case-key"), "kebabCaseKey")
        XCTAssertEqual(CodableGenerator.propertyName(for: "2fa"), "_2fa")
        XCTAssertEqual(CodableGenerator.singularize("categories"), "category")
        XCTAssertEqual(CodableGenerator.singularize("addresses"), "address")
        XCTAssertEqual(CodableGenerator.singularize("boxes"), "box")
        XCTAssertEqual(CodableGenerator.singularize("data"), "dataItem")
    }
}

final class Base64Tests: XCTestCase {
    func testRoundTrip() throws {
        XCTAssertEqual(Base64Tool.encode("hello?>"), "aGVsbG8/Pg==")
        XCTAssertEqual(Base64Tool.encode("hello?>", urlSafe: true, padded: false), "aGVsbG8_Pg")
        XCTAssertEqual(try Base64Tool.decodeToText("aGVsbG8_Pg"), "hello?>")
        XCTAssertEqual(try Base64Tool.decodeToText(" aGVs\nbG8/Pg== "), "hello?>")
    }

    func testRejectsInvalid() {
        XCTAssertThrowsError(try Base64Tool.decode("not base64!"))
        XCTAssertThrowsError(try Base64Tool.decode("abcde"))
    }

    func testHexDump() {
        XCTAssertEqual(Base64Tool.hexDump(Data("Hi\n".utf8)), "00000000  48 69 0a" + String(repeating: " ", count: 39) + "  |Hi.|")
    }
}

final class JWTTests: XCTestCase {
    // {"alg":"HS256","typ":"JWT"} . {"sub":"123","name":"Ryan","iat":1700000000,"exp":1700003600,"aud":["a","b"]}
    let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
        + Base64Tool.encode(#"{"sub":"123","name":"Ryan","iat":1700000000,"exp":1700003600,"aud":["a","b"]}"#, urlSafe: true, padded: false)
        + ".c2lnbmF0dXJl"

    func testDecode() throws {
        let jwt = try JWTDecoder.decode("Bearer " + token)
        XCTAssertEqual(jwt.algorithm, "HS256")
        XCTAssertEqual(jwt.subject, "123")
        XCTAssertEqual(jwt.audience, ["a", "b"])
        XCTAssertEqual(jwt.issuedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(jwt.isExpired(at: Date(timeIntervalSince1970: 1_700_000_001)), false)
        XCTAssertEqual(jwt.isExpired(at: Date(timeIntervalSince1970: 1_800_000_000)), true)
        XCTAssertEqual(jwt.payload.objectValue?.map(\.key), ["sub", "name", "iat", "exp", "aud"])
    }

    func testErrors() {
        XCTAssertThrowsError(try JWTDecoder.decode("a.b")) { XCTAssertEqual($0 as? JWTDecoder.DecodeError, .wrongSegmentCount(2)) }
        XCTAssertThrowsError(try JWTDecoder.decode("eyJ!.e30.x"))
    }
}

final class TimestampTests: XCTestCase {
    func testDetectsUnits() {
        XCTAssertEqual(TimestampTool.parse("1700000000")?.detectedUnit, .seconds)
        XCTAssertEqual(TimestampTool.parse("1700000000123")?.detectedUnit, .milliseconds)
        XCTAssertEqual(TimestampTool.parse("1700000000123456")?.detectedUnit, .microseconds)
        XCTAssertEqual(TimestampTool.parse("1700000000123")?.seconds, 1_700_000_000)
        XCTAssertEqual(TimestampTool.parse("1700000000")?.iso8601UTC, "2023-11-14T22:13:20Z")
    }

    func testParsesISO8601() {
        XCTAssertEqual(TimestampTool.parse("2023-11-14T22:13:20Z")?.seconds, 1_700_000_000)
        XCTAssertEqual(TimestampTool.parse("2023-11-14T22:13:20.500Z")?.milliseconds, 1_700_000_000_500)
        XCTAssertNil(TimestampTool.parse("yesterday"))
    }

    func testRelative() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(TimestampTool.relativeDescription(of: now.addingTimeInterval(-7200), now: now), "2 hours ago")
        XCTAssertEqual(TimestampTool.relativeDescription(of: now.addingTimeInterval(86_400 * 3), now: now), "in 3 days")
        XCTAssertEqual(TimestampTool.relativeDescription(of: now, now: now), "now")
    }
}
