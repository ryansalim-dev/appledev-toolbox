import Foundation

/// A crash report parsed from Apple's `.ips` format (iOS 15+ / macOS 12+).
///
/// An `.ips` file is one line of JSON metadata followed by a JSON body. Apple adds
/// fields from release to release, so everything is read leniently: unknown keys
/// are ignored and every field is optional.
public struct CrashReport: Sendable {
    public struct ExceptionInfo: Equatable, Sendable {
        public var type: String?
        public var signal: String?
        public var codes: String?
        public var subtype: String?
        public var message: String?
    }

    public struct TerminationInfo: Equatable, Sendable {
        public var namespace: String?
        public var code: Int?
        public var indicator: String?
        public var byProcess: String?
        public var reasons: [String]
    }

    public struct Frame: Equatable, Sendable {
        public var imageIndex: Int?
        public var imageOffset: UInt64?
        public var symbol: String?
        public var symbolLocation: Int?
        public var sourceFile: String?
        public var sourceLine: Int?

        /// Absolute address = image load address + offset.
        public func address(in images: [BinaryImage]) -> UInt64? {
            guard let i = imageIndex, images.indices.contains(i), let offset = imageOffset else { return nil }
            return images[i].loadAddress &+ offset
        }

        public var isSymbolicated: Bool { symbol != nil }
    }

    public struct Thread: Equatable, Sendable {
        public var index: Int
        public var name: String?
        public var queue: String?
        public var triggered: Bool
        public var frames: [Frame]
    }

    public struct BinaryImage: Equatable, Sendable {
        public var index: Int
        public var name: String?
        public var path: String?
        public var uuid: String?
        public var arch: String?
        public var loadAddress: UInt64
        public var size: UInt64?
        /// "P" marks the crashing process's own binary; "S" a shared-cache image.
        public var source: String?

        /// The UUID in the uppercase dashed form Spotlight and dwarfdump use.
        public var normalizedUUID: String? { uuid.map { CrashReport.normalizeUUID($0) } }
    }

    // Metadata
    public var bugType: String?
    public var incidentID: String?
    public var appName: String?
    public var bundleID: String?
    public var appVersion: String?
    public var buildVersion: String?
    public var processName: String?
    public var processPath: String?
    public var pid: Int?
    public var parentProcess: String?
    public var osVersion: String?
    public var hardwareModel: String?
    public var cpuType: String?
    public var captureTime: String?
    public var launchTime: String?

    // Crash details
    public var exception: ExceptionInfo?
    public var termination: TerminationInfo?
    public var faultingThread: Int?
    public var threads: [Thread]
    public var lastExceptionBacktrace: [Frame]
    public var images: [BinaryImage]
    /// Application-specific messages, e.g. "Fatal error: Unexpectedly found nil…".
    public var applicationMessages: [String]

    /// The parsed JSON, for a raw view and fields this model doesn't surface.
    public var rawHeader: JSONValue
    public var rawBody: JSONValue?

    /// The thread that crashed, if any.
    public var crashedThread: Thread? {
        threads.first(where: \.triggered) ?? faultingThread.flatMap { idx in threads.first(where: { $0.index == idx }) }
    }

    /// True for bug type 309 (the standard crash report). Other types (hangs, jetsam…) parse, but with fewer fields.
    public var isCrash: Bool { bugType == "309" }

    static func normalizeUUID(_ uuid: String) -> String {
        let hex = uuid.uppercased().filter { $0.isHexDigit }
        guard hex.count == 32 else { return uuid.uppercased() }
        let chars = Array(hex)
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }
        return groups.joined(separator: "-")
    }
}

// MARK: - Parsing

public enum CrashReportParser {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case invalidHeader(String)
        case invalidBody(String)

        public var description: String {
            switch self {
            case .empty: return "The file is empty."
            case .invalidHeader(let d): return "The first line isn't valid .ips metadata: \(d)"
            case .invalidBody(let d): return "The crash report body isn't valid JSON: \(d)"
            }
        }
    }

    /// Quick check for input detection: first line is a JSON object with `bug_type`.
    public static func looksLikeIPS(_ text: String) -> Bool {
        let firstLine = text.prefix(while: { $0 != "\n" && $0 != "\r" })
        guard firstLine.hasPrefix("{"), firstLine.contains("\"bug_type\"") else { return false }
        return (try? JSONParser.parse(String(firstLine)))?["bug_type"] != nil
    }

    public static func parse(_ data: Data) throws -> CrashReport {
        try parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) throws -> CrashReport {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        let headerText: Substring
        let bodyText: Substring
        if let newline = trimmed.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            headerText = trimmed[..<newline]
            bodyText = trimmed[newline...]
        } else {
            headerText = trimmed[...]
            bodyText = ""
        }

        let header: JSONValue
        do { header = try JSONParser.parse(String(headerText)) } catch { throw ParseError.invalidHeader(String(describing: error)) }

        var body: JSONValue?
        let bodyString = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bodyString.isEmpty {
            do { body = try JSONParser.parse(bodyString) } catch { throw ParseError.invalidBody(String(describing: error)) }
        }
        return build(header: header, body: body)
    }

    static func build(header: JSONValue, body: JSONValue?) -> CrashReport {
        let b = body ?? .object([])
        let images = (b["usedImages"]?.arrayValue ?? []).enumerated().map { index, img in
            CrashReport.BinaryImage(
                index: index,
                name: img["name"]?.stringValue ?? img["path"]?.stringValue.map { ($0 as NSString).lastPathComponent },
                path: img["path"]?.stringValue,
                uuid: img["uuid"]?.stringValue,
                arch: img["arch"]?.stringValue,
                loadAddress: img["base"]?.uint64Value ?? 0,
                size: img["size"]?.uint64Value,
                source: img["source"]?.stringValue
            )
        }

        let threads = (b["threads"]?.arrayValue ?? []).enumerated().map { index, t in
            CrashReport.Thread(
                index: index,
                name: t["name"]?.stringValue,
                queue: t["queue"]?.stringValue,
                triggered: t["triggered"]?.boolValue ?? false,
                frames: frames(t["frames"])
            )
        }

        var exception: CrashReport.ExceptionInfo?
        if let e = b["exception"] {
            exception = .init(
                type: e["type"]?.stringValue,
                signal: e["signal"]?.stringValue,
                codes: e["codes"]?.stringValue,
                subtype: e["subtype"]?.stringValue,
                message: e["message"]?.stringValue
            )
        }

        var termination: CrashReport.TerminationInfo?
        if let t = b["termination"] {
            termination = .init(
                namespace: t["namespace"]?.stringValue,
                code: t["code"]?.intValue,
                indicator: t["indicator"]?.stringValue,
                byProcess: t["byProc"]?.stringValue,
                reasons: t["reasons"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        }

        // "asi" is { processName: [messages] }.
        var messages: [String] = []
        for member in b["asi"]?.objectValue ?? [] {
            messages += member.value.arrayValue?.compactMap(\.stringValue) ?? []
        }

        var osVersion: String?
        if let os = b["osVersion"], let train = os["train"]?.stringValue {
            osVersion = os["build"]?.stringValue.map { "\(train) (\($0))" } ?? train
        } else {
            osVersion = header["os_version"]?.stringValue
        }

        let bundleInfo = b["bundleInfo"]
        return CrashReport(
            bugType: header["bug_type"]?.stringValue ?? b["bug_type"]?.stringValue,
            incidentID: header["incident_id"]?.stringValue ?? b["incident"]?.stringValue,
            appName: header["app_name"]?.stringValue ?? b["procName"]?.stringValue,
            bundleID: header["bundleID"]?.stringValue ?? bundleInfo?["CFBundleIdentifier"]?.stringValue,
            appVersion: header["app_version"]?.stringValue ?? bundleInfo?["CFBundleShortVersionString"]?.stringValue,
            buildVersion: header["build_version"]?.stringValue ?? bundleInfo?["CFBundleVersion"]?.stringValue,
            processName: b["procName"]?.stringValue ?? header["name"]?.stringValue,
            processPath: b["procPath"]?.stringValue,
            pid: b["pid"]?.intValue,
            parentProcess: b["parentProc"]?.stringValue,
            osVersion: osVersion,
            hardwareModel: b["modelCode"]?.stringValue,
            cpuType: b["cpuType"]?.stringValue,
            captureTime: b["captureTime"]?.stringValue ?? header["timestamp"]?.stringValue,
            launchTime: b["procLaunch"]?.stringValue,
            exception: exception,
            termination: termination,
            faultingThread: b["faultingThread"]?.intValue,
            threads: threads,
            lastExceptionBacktrace: frames(b["lastExceptionBacktrace"]),
            images: images,
            applicationMessages: messages,
            rawHeader: header,
            rawBody: body
        )
    }

    private static func frames(_ value: JSONValue?) -> [CrashReport.Frame] {
        (value?.arrayValue ?? []).map { f in
            CrashReport.Frame(
                imageIndex: f["imageIndex"]?.intValue,
                imageOffset: f["imageOffset"]?.uint64Value,
                symbol: f["symbol"]?.stringValue,
                symbolLocation: f["symbolLocation"]?.intValue,
                sourceFile: f["sourceFile"]?.stringValue,
                sourceLine: f["sourceLine"]?.intValue
            )
        }
    }
}
