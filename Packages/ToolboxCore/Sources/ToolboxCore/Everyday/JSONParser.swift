import Foundation

public struct JSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    /// 1-based line of the problem.
    public let line: Int
    /// 1-based column (in UTF-8 bytes) of the problem.
    public let column: Int

    public var description: String { "\(message) at line \(line), column \(column)" }
}

/// A strict RFC 8259 parser that produces an order-preserving `JSONValue`
/// and reports errors with line and column.
public struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private static let maxDepth = 512

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Array(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try parse([UInt8](data))
    }

    private static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        var parser = JSONParser(bytes: bytes)
        // Skip a UTF-8 byte order mark.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        if parser.index != bytes.count {
            throw parser.error("Unexpected text after the end of the JSON value")
        }
        return value
    }

    // MARK: - Values

    private mutating func parseValue() throws -> JSONValue {
        guard let byte = peek() else { throw error("Unexpected end of input") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("Unexpected character '\(Character(Unicode.Scalar(byte)))'")
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        index += 1 // {
        var members: [JSONMember] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "}") { index += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw error("Expected a quoted key") }
            let key = try parseString()
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { throw error("Expected ':' after key \"\(key)\"") }
            index += 1
            skipWhitespace()
            let value = try parseValue()
            members.append(JSONMember(key: key, value: value))
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(members)
            case nil: throw error("Unexpected end of input inside an object")
            default: throw error("Expected ',' or '}' in object")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        index += 1 // [
        var items: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(items)
            case nil: throw error("Unexpected end of input inside an array")
            default: throw error("Expected ',' or ']' in array")
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1 // opening quote
        var buffer: [UInt8] = []
        while true {
            guard let byte = peek() else { throw error("Unterminated string") }
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                guard let escape = peek() else { throw error("Unterminated escape sequence") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try parseUnicodeEscape()
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    index -= 1
                    throw error("Invalid escape '\\\(Character(Unicode.Scalar(escape)))'")
                }
            case 0x00..<0x20:
                throw error("Control characters must be escaped inside strings")
            default:
                buffer.append(byte)
                index += 1
            }
        }
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let high = try readHex4()
        if (0xD800...0xDBFF).contains(high) {
            // Surrogate pair: expect \uDC00-\uDFFF next.
            guard peek() == UInt8(ascii: "\\"), peek(offset: 1) == UInt8(ascii: "u") else {
                throw error("Unpaired UTF-16 surrogate")
            }
            index += 2
            let low = try readHex4()
            guard (0xDC00...0xDFFF).contains(low) else { throw error("Invalid UTF-16 low surrogate") }
            let value = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { throw error("Invalid Unicode escape") }
            return scalar
        }
        if (0xDC00...0xDFFF).contains(high) { throw error("Unpaired UTF-16 surrogate") }
        guard let scalar = Unicode.Scalar(high) else { throw error("Invalid Unicode escape") }
        return scalar
    }

    private mutating func readHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw error("Expected four hex digits after \\u") }
        index += 4
        return value
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        if peek() == UInt8(ascii: "-") { index += 1 }
        guard let first = peek(), isDigit(first) else { throw error("Expected a digit") }
        if first == UInt8(ascii: "0") {
            index += 1
            if let next = peek(), isDigit(next) { throw error("Numbers can't have leading zeros") }
        } else {
            while let b = peek(), isDigit(b) { index += 1 }
        }
        if peek() == UInt8(ascii: ".") {
            index += 1
            guard let b = peek(), isDigit(b) else { throw error("Expected a digit after the decimal point") }
            while let b = peek(), isDigit(b) { index += 1 }
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            index += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { index += 1 }
            guard let b = peek(), isDigit(b) else { throw error("Expected a digit in the exponent") }
            while let b = peek(), isDigit(b) { index += 1 }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func expectLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw error("Invalid literal, expected '\(literal)'")
        }
        index += expected.count
    }

    // MARK: - Helpers

    private mutating func enterContainer() throws {
        depth += 1
        if depth > JSONParser.maxDepth { throw error("JSON is nested too deeply") }
    }

    private func peek(offset: Int = 0) -> UInt8? {
        let i = index + offset
        return i < bytes.count ? bytes[i] : nil
    }

    private func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }

    private mutating func skipWhitespace() {
        while let b = peek(), b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 { index += 1 }
    }

    private func error(_ message: String) -> JSONParseError {
        var line = 1
        var column = 1
        for b in bytes[..<min(index, bytes.count)] {
            if b == 0x0A { line += 1; column = 1 } else { column += 1 }
        }
        return JSONParseError(message: message, line: line, column: column)
    }
}
