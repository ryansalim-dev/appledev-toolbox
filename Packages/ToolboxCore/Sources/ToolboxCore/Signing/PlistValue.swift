import Foundation

/// A property-list value, used for entitlements and other free-form plist content.
public indirect enum PlistValue: Equatable, Sendable, Decodable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    public init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [PlistValue] = []
            while !unkeyed.isAtEnd { items.append(try unkeyed.decode(PlistValue.self)) }
            self = .array(items)
            return
        }
        if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
            var dict: [String: PlistValue] = [:]
            for key in keyed.allKeys { dict[key.stringValue] = try keyed.decode(PlistValue.self, forKey: key) }
            self = .dictionary(dict)
            return
        }
        let single = try decoder.singleValueContainer()
        // Order matters: plist decoders will happily turn <integer>1</integer> into a Bool
        // on some platforms, and <true/> into 1, so try the narrowest match first.
        if let v = try? single.decode(Bool.self) { self = .bool(v); return }
        if let v = try? single.decode(Int.self) { self = .integer(v); return }
        if let v = try? single.decode(Double.self) { self = .real(v); return }
        if let v = try? single.decode(Date.self) { self = .date(v); return }
        if let v = try? single.decode(Data.self) { self = .data(v); return }
        self = .string(try single.decode(String.self))
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [PlistValue]? { if case .array(let a) = self { return a }; return nil }
    public var dictionaryValue: [String: PlistValue]? { if case .dictionary(let d) = self { return d }; return nil }

    /// A short human-readable rendering, used in tables.
    public var displayString: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "YES" : "NO"
        case .integer(let i): return String(i)
        case .real(let d): return String(d)
        case .date(let d): return TimestampTool.iso8601(d, timeZone: TimeZone(identifier: "UTC")!)
        case .data(let d): return "<\(d.count) bytes>"
        case .array(let a): return a.map(\.displayString).joined(separator: ", ")
        case .dictionary(let d): return "{" + d.keys.sorted().map { "\($0) = \(d[$0]!.displayString)" }.joined(separator: "; ") + "}"
        }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}
