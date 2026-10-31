import Foundation

/// A JSON document that keeps object keys in their original order.
///
/// `JSONSerialization` loses key order, which matters both for pretty-printing
/// ("don't reshuffle my payload") and for generating `Codable` types whose
/// properties follow the order in the sample.
public enum JSONValue: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    /// The number exactly as written, so large integers and decimals round-trip.
    case number(String)
    case bool(Bool)
    case null
}

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

// MARK: - Lenient accessors

public extension JSONValue {
    /// The value for `key` if this is an object (first match wins).
    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first(where: { $0.key == key })?.value
    }

    subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let n): return Int(n) ?? Double(n).flatMap { $0.isFinite ? Int(exactly: $0.rounded(.towardZero)) : nil }
        case .string(let s): return Int(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var uint64Value: UInt64? {
        switch self {
        case .number(let n): return UInt64(n) ?? Double(n).flatMap { $0 >= 0 && $0.isFinite ? UInt64(exactly: $0.rounded(.towardZero)) : nil }
        case .string(let s):
            if s.hasPrefix("0x") || s.hasPrefix("0X") { return UInt64(s.dropFirst(2), radix: 16) }
            return UInt64(s)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return Double(n)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n == "0" ? false : (n == "1" ? true : nil)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var objectValue: [JSONMember]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var isNull: Bool { self == .null }
}

// MARK: - Serialization

public extension JSONValue {
    /// Pretty-printed JSON. Keys keep their original order unless `sortKeys` is set.
    func formatted(indent: Int = 2, sortKeys: Bool = false) -> String {
        var out = ""
        write(to: &out, indentUnit: String(repeating: " ", count: max(0, indent)), level: 0, pretty: true, sortKeys: sortKeys)
        return out
    }

    /// Compact JSON with no whitespace.
    func minified(sortKeys: Bool = false) -> String {
        var out = ""
        write(to: &out, indentUnit: "", level: 0, pretty: false, sortKeys: sortKeys)
        return out
    }

    private func write(to out: inout String, indentUnit: String, level: Int, pretty: Bool, sortKeys: Bool) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += JSONValue.quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: indentUnit, count: level + 1) }
                item.write(to: &out, indentUnit: indentUnit, level: level + 1, pretty: pretty, sortKeys: sortKeys)
            }
            if pretty { out += "\n" + String(repeating: indentUnit, count: level) }
            out += "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            let ordered = sortKeys ? members.sorted { $0.key < $1.key } : members
            out += "{"
            for (i, member) in ordered.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: indentUnit, count: level + 1) }
                out += JSONValue.quote(member.key)
                out += pretty ? ": " : ":"
                member.value.write(to: &out, indentUnit: indentUnit, level: level + 1, pretty: pretty, sortKeys: sortKeys)
            }
            if pretty { out += "\n" + String(repeating: indentUnit, count: level) }
            out += "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
