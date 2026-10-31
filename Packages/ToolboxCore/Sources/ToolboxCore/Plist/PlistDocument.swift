import Foundation

/// A property list loaded for viewing: its root value, original format, and helpers to render it.
public struct PlistDocument: Equatable, Sendable {
    public enum Format: String, Sendable {
        case xml = "XML"
        case binary = "Binary"
        case other = "Other"
    }

    public let root: PlistValue
    public let format: Format

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        public var description: String {
            switch self {
            case .invalid(let detail): return "This isn't a readable property list: \(detail)"
            }
        }
    }

    public static func parse(_ data: Data) throws -> PlistDocument {
        let format: Format
        if data.starts(with: Data("bplist".utf8)) {
            format = .binary
        } else if let head = String(data: data.prefix(256), encoding: .utf8),
                  head.contains("<?xml") || head.contains("<plist") {
            format = .xml
        } else {
            format = .other
        }
        do {
            return PlistDocument(root: try PropertyListDecoder().decode(PlistValue.self, from: data), format: format)
        } catch {
            throw ParseError.invalid(String(describing: error))
        }
    }

    public init(root: PlistValue, format: Format = .xml) {
        self.root = root
        self.format = format
    }

    // MARK: - Tree for outline views

    public struct Node: Identifiable, Equatable, Sendable {
        /// Key path such as `NSAppTransportSecurity.NSExceptionDomains.example.com` or `items[2]`.
        public let id: String
        public let key: String
        public let type: String
        public let value: String
        public let children: [Node]?
    }

    /// The root's children as outline nodes. Dictionary keys are sorted, like Xcode shows them.
    public var nodes: [Node] {
        PlistDocument.children(of: root, path: "") ?? [PlistDocument.node(key: "Root", value: root, path: "Root")]
    }

    static func children(of value: PlistValue, path: String) -> [Node]? {
        switch value {
        case .dictionary(let dict):
            return dict.keys.sorted().map { key in
                node(key: key, value: dict[key]!, path: path.isEmpty ? key : "\(path).\(key)")
            }
        case .array(let items):
            return items.enumerated().map { i, item in
                node(key: "Item \(i)", value: item, path: "\(path)[\(i)]")
            }
        default:
            return nil
        }
    }

    static func node(key: String, value: PlistValue, path: String) -> Node {
        let summary: String
        switch value {
        case .dictionary(let d): summary = "\(d.count) key\(d.count == 1 ? "" : "s")"
        case .array(let a): summary = "\(a.count) item\(a.count == 1 ? "" : "s")"
        default: summary = value.displayString
        }
        return Node(id: path, key: key, type: value.typeName, value: summary, children: children(of: value, path: path))
    }

    // MARK: - Rendering

    /// XML property list text, keys sorted.
    public func xmlString() -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        PlistDocument.writeXML(root, indent: 0, to: &out)
        out += "</plist>\n"
        return out
    }

    static func writeXML(_ value: PlistValue, indent: Int, to out: inout String) {
        let pad = String(repeating: "\t", count: indent)
        switch value {
        case .string(let s): out += "\(pad)<string>\(escapeXML(s))</string>\n"
        case .bool(let b): out += "\(pad)<\(b ? "true" : "false")/>\n"
        case .integer(let i): out += "\(pad)<integer>\(i)</integer>\n"
        case .real(let d): out += "\(pad)<real>\(d)</real>\n"
        case .date(let d): out += "\(pad)<date>\(TimestampTool.iso8601(d, timeZone: TimeZone(identifier: "UTC")!))</date>\n"
        case .data(let d): out += "\(pad)<data>\(d.base64EncodedString())</data>\n"
        case .array(let items):
            if items.isEmpty { out += "\(pad)<array/>\n"; return }
            out += "\(pad)<array>\n"
            for item in items { writeXML(item, indent: indent + 1, to: &out) }
            out += "\(pad)</array>\n"
        case .dictionary(let dict):
            if dict.isEmpty { out += "\(pad)<dict/>\n"; return }
            out += "\(pad)<dict>\n"
            for key in dict.keys.sorted() {
                out += "\(pad)\t<key>\(escapeXML(key))</key>\n"
                writeXML(dict[key]!, indent: indent + 1, to: &out)
            }
            out += "\(pad)</dict>\n"
        }
    }

    static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// JSON rendering (dates as ISO 8601, data as Base64), keys sorted.
    public func jsonValue() -> JSONValue { PlistDocument.json(root) }

    static func json(_ value: PlistValue) -> JSONValue {
        switch value {
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .integer(let i): return .number(String(i))
        case .real(let d): return d.isFinite ? .number(String(d)) : .string(String(d))
        case .date(let d): return .string(TimestampTool.iso8601(d, timeZone: TimeZone(identifier: "UTC")!))
        case .data(let d): return .string(d.base64EncodedString())
        case .array(let items): return .array(items.map(json))
        case .dictionary(let dict): return .object(dict.keys.sorted().map { JSONMember(key: $0, value: json(dict[$0]!)) })
        }
    }
}

public extension PlistValue {
    var typeName: String {
        switch self {
        case .string: return "String"
        case .bool: return "Boolean"
        case .integer: return "Number"
        case .real: return "Number"
        case .date: return "Date"
        case .data: return "Data"
        case .array: return "Array"
        case .dictionary: return "Dictionary"
        }
    }
}

// MARK: - Diff

public enum PlistDiff {
    public struct Change: Equatable, Sendable {
        public enum Kind: String, Sendable { case added, removed, changed }
        public var kind: Kind
        public var path: String
        public var old: String?
        public var new: String?
    }

    /// Differences from `old` to `new`. Arrays of strings (like associated domains or
    /// keychain groups) are compared as sets, so reordering isn't reported.
    public static func compare(_ old: PlistValue, _ new: PlistValue, path: String = "") -> [Change] {
        switch (old, new) {
        case (.dictionary(let a), .dictionary(let b)):
            var changes: [Change] = []
            for key in Set(a.keys).union(b.keys).sorted() {
                let p = path.isEmpty ? key : "\(path).\(key)"
                switch (a[key], b[key]) {
                case (nil, let v?): changes.append(Change(kind: .added, path: p, old: nil, new: v.displayString))
                case (let v?, nil): changes.append(Change(kind: .removed, path: p, old: v.displayString, new: nil))
                case (let x?, let y?): changes += compare(x, y, path: p)
                default: break
                }
            }
            return changes
        case (.array(let a), .array(let b)):
            let aStrings = a.compactMap(\.stringValue)
            let bStrings = b.compactMap(\.stringValue)
            if aStrings.count == a.count, bStrings.count == b.count {
                let removed = aStrings.filter { !bStrings.contains($0) }
                let added = bStrings.filter { !aStrings.contains($0) }
                return removed.map { Change(kind: .removed, path: path, old: $0, new: nil) }
                    + added.map { Change(kind: .added, path: path, old: nil, new: $0) }
            }
            var changes: [Change] = []
            for i in 0..<max(a.count, b.count) {
                let p = "\(path)[\(i)]"
                if i >= a.count { changes.append(Change(kind: .added, path: p, old: nil, new: b[i].displayString)) }
                else if i >= b.count { changes.append(Change(kind: .removed, path: p, old: a[i].displayString, new: nil)) }
                else { changes += compare(a[i], b[i], path: p) }
            }
            return changes
        default:
            return old == new ? [] : [Change(kind: .changed, path: path.isEmpty ? "Root" : path, old: old.displayString, new: new.displayString)]
        }
    }
}

// MARK: - App bundles

public enum AppBundleFiles {
    /// `Info.plist` lives at the top of an iOS `.app` and under `Contents/` for macOS.
    public static func infoPlistURL(inApp app: URL) -> URL {
        let mac = app.appendingPathComponent("Contents/Info.plist")
        return FileManager.default.fileExists(atPath: mac.path) ? mac : app.appendingPathComponent("Info.plist")
    }

    public static func embeddedProfileURL(inApp app: URL) -> URL? {
        let candidates = [
            app.appendingPathComponent("embedded.mobileprovision"),
            app.appendingPathComponent("Contents/embedded.provisionprofile"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func privacyManifestURL(inApp app: URL) -> URL? {
        let candidates = [
            app.appendingPathComponent("PrivacyInfo.xcprivacy"),
            app.appendingPathComponent("Contents/Resources/PrivacyInfo.xcprivacy"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Arguments for `/usr/bin/codesign` that print a signed binary's entitlements as XML.
    public static func codesignEntitlementsArguments(path: String) -> [String] {
        ["-d", "--entitlements", "-", "--xml", path]
    }

    /// The first `Payload/*.app` inside an unzipped `.ipa`.
    public static func appInUnzippedIPA(_ root: URL) -> URL? {
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }
}
