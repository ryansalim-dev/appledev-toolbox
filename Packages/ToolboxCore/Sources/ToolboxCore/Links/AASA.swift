import Foundation

/// A parsed `apple-app-site-association` file (universal links, shared web credentials, App Clips).
public struct AASAFile: Equatable, Sendable {
    public struct Component: Equatable, Sendable {
        /// `"/"`: path pattern. `*` matches any run of characters, `?` exactly one.
        public var path: String?
        /// `"?"`: either a pattern for the whole query, or per-parameter patterns.
        public var query: Query?
        /// `"#"`: fragment pattern.
        public var fragment: String?
        public var exclude: Bool
        public var comment: String?
        public var caseSensitive: Bool?
        public var percentEncoded: Bool?

        public enum Query: Equatable, Sendable {
            case whole(String)
            case items([String: String])
        }
    }

    public struct Detail: Equatable, Sendable {
        public var appIDs: [String]
        public var components: [Component]
        /// Pre-iOS 13 `paths` array (`"NOT /path"` excludes).
        public var legacyPaths: [String]
    }

    public var details: [Detail]
    public var defaultCaseSensitive: Bool
    public var defaultPercentEncoded: Bool
    public var webCredentialsApps: [String]
    public var appClipsApps: [String]
    public var raw: JSONValue

    public struct Issue: Equatable, Sendable {
        public enum Severity: Sendable { case error, warning }
        public var severity: Severity
        public var message: String

        public init(severity: Severity, message: String) {
            self.severity = severity
            self.message = message
        }
    }

    // MARK: - Parsing

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case invalidJSON(String)
        case notAnObject
        public var description: String {
            switch self {
            case .invalidJSON(let d): return "The file isn't valid JSON: \(d)"
            case .notAnObject: return "The file must be a JSON object."
            }
        }
    }

    public static func parse(_ data: Data) throws -> (file: AASAFile, issues: [Issue]) {
        let json: JSONValue
        do { json = try JSONParser.parse(data) } catch { throw ParseError.invalidJSON(String(describing: error)) }
        guard json.objectValue != nil else { throw ParseError.notAnObject }

        var issues: [Issue] = []
        func error(_ m: String) { issues.append(Issue(severity: .error, message: m)) }
        func warning(_ m: String) { issues.append(Issue(severity: .warning, message: m)) }

        let applinks = json["applinks"]
        let defaults = applinks?["defaults"]
        var details: [Detail] = []

        if let applinks {
            let rawDetails = applinks["details"]?.arrayValue ?? []
            if applinks["details"] == nil { error("applinks has no \"details\" array.") }
            if rawDetails.isEmpty, applinks["details"] != nil { error("applinks.details is empty, so no app will open links.") }

            for (i, d) in rawDetails.enumerated() {
                var appIDs = d["appIDs"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if let single = d["appID"]?.stringValue { appIDs.append(single) }
                if appIDs.isEmpty { error("details[\(i)] has no appIDs.") }
                for id in appIDs where !isValidAppID(id) {
                    error("\"\(id)\" isn't a valid app ID. It should be TEAMID.bundle.id, e.g. ABCDE12345.com.example.app.")
                }

                let components = (d["components"]?.arrayValue ?? []).enumerated().map { j, c in
                    parseComponent(c, location: "details[\(i)].components[\(j)]", warn: warning)
                }
                let paths = d["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if !paths.isEmpty, components.isEmpty {
                    warning("details[\(i)] uses the legacy \"paths\" key. iOS 13+ prefers \"components\"; keep paths only if you support iOS 12.")
                }
                if components.isEmpty, paths.isEmpty {
                    warning("details[\(i)] has no components or paths, so it matches nothing.")
                }
                details.append(Detail(appIDs: appIDs, components: components, legacyPaths: paths))
            }
            if applinks["apps"] != nil, applinks["apps"]?.arrayValue?.isEmpty == false {
                warning("applinks.apps should be an empty array (or omitted); app IDs go in details.")
            }
        }

        let webCredentials = json["webcredentials"]?["apps"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let appClips = json["appclips"]?["apps"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for id in webCredentials + appClips where !isValidAppID(id) {
            error("\"\(id)\" isn't a valid app ID. It should be TEAMID.bundle.id.")
        }
        if applinks == nil, json["webcredentials"] == nil, json["appclips"] == nil {
            error("The file has no applinks, webcredentials or appclips section.")
        }

        let file = AASAFile(
            details: details,
            defaultCaseSensitive: defaults?["caseSensitive"]?.boolValue ?? true,
            defaultPercentEncoded: defaults?["percentEncoded"]?.boolValue ?? true,
            webCredentialsApps: webCredentials,
            appClipsApps: appClips,
            raw: json
        )
        return (file, issues)
    }

    static func parseComponent(_ c: JSONValue, location: String, warn: (String) -> Void) -> Component {
        var query: Component.Query?
        if let q = c["?"] {
            if let s = q.stringValue {
                query = .whole(s)
            } else if let members = q.objectValue {
                var items: [String: String] = [:]
                for m in members { items[m.key] = m.value.stringValue ?? "" }
                query = .items(items)
            }
        }
        let path = c["/"]?.stringValue
        if let path, !(path.hasPrefix("/") || path.hasPrefix("*") || path.hasPrefix("?")) {
            warn("\(location) path \"\(path)\" should start with \"/\".")
        }
        if path == nil, query == nil, c["#"] == nil {
            warn("\(location) has no \"/\", \"?\" or \"#\" key, so it matches every URL.")
        }
        return Component(
            path: path,
            query: query,
            fragment: c["#"]?.stringValue,
            exclude: c["exclude"]?.boolValue ?? false,
            comment: c["comment"]?.stringValue,
            caseSensitive: c["caseSensitive"]?.boolValue,
            percentEncoded: c["percentEncoded"]?.boolValue
        )
    }

    /// `TEAMID.bundle.id`, where the Team ID is 10 uppercase letters/digits.
    static func isValidAppID(_ id: String) -> Bool {
        guard let dot = id.firstIndex(of: ".") else { return false }
        let team = id[..<dot]
        let bundle = id[id.index(after: dot)...]
        return team.count == 10 && team.allSatisfy { $0.isNumber || ($0.isLetter && $0.isUppercase) } && !bundle.isEmpty
    }
}

// MARK: - URL matching

public extension AASAFile {
    struct Match: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            /// The URL opens the app(s).
            case opensApp
            /// A rule matched but excludes the URL, so it opens in Safari.
            case excluded
            /// No rule matched.
            case noMatch
        }
        public var outcome: Outcome
        public var appIDs: [String]
        /// Human-readable description of the rule that decided it.
        public var rule: String?
    }

    /// Evaluates a URL the way iOS does: each detail's rules in order, first matching rule wins.
    func match(_ url: URL) -> [Match] {
        details.map { detail in
            if !detail.components.isEmpty {
                for component in detail.components where matches(component, url: url) {
                    return Match(outcome: component.exclude ? .excluded : .opensApp, appIDs: detail.appIDs, rule: describe(component))
                }
            } else {
                for raw in detail.legacyPaths {
                    let exclude = raw.hasPrefix("NOT ")
                    let pattern = exclude ? String(raw.dropFirst(4)) : raw
                    let path = url.path.isEmpty ? "/" : url.path
                    if AASAFile.wildcardMatch(pattern: pattern, text: path, caseSensitive: true) {
                        return Match(outcome: exclude ? .excluded : .opensApp, appIDs: detail.appIDs, rule: "paths: \"\(raw)\"")
                    }
                }
            }
            return Match(outcome: .noMatch, appIDs: detail.appIDs, rule: nil)
        }
    }

    internal func matches(_ c: Component, url: URL) -> Bool {
        let caseSensitive = c.caseSensitive ?? defaultCaseSensitive
        let percentEncoded = c.percentEncoded ?? defaultPercentEncoded
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)

        if let pattern = c.path {
            let rawPath = percentEncoded ? (parts?.percentEncodedPath ?? url.path) : (parts?.path ?? url.path)
            let path = rawPath.isEmpty ? "/" : rawPath
            if !AASAFile.wildcardMatch(pattern: pattern, text: path, caseSensitive: caseSensitive) { return false }
        }

        switch c.query {
        case .whole(let pattern)?:
            let query = (percentEncoded ? parts?.percentEncodedQuery : parts?.query) ?? ""
            if !AASAFile.wildcardMatch(pattern: pattern, text: query, caseSensitive: caseSensitive) { return false }
        case .items(let patterns)?:
            let items = parts?.queryItems ?? []
            for (name, pattern) in patterns {
                let value = items.first(where: { $0.name == name })?.value
                // A missing parameter only matches patterns that accept an empty string.
                if !AASAFile.wildcardMatch(pattern: pattern, text: value ?? "", caseSensitive: caseSensitive) { return false }
                if value == nil, pattern != "*" { return false }
            }
        case nil:
            break
        }

        if let pattern = c.fragment {
            let fragment = (percentEncoded ? parts?.percentEncodedFragment : parts?.fragment) ?? ""
            if !AASAFile.wildcardMatch(pattern: pattern, text: fragment, caseSensitive: caseSensitive) { return false }
        }
        return true
    }

    func describe(_ c: Component) -> String {
        var parts: [String] = []
        if let p = c.path { parts.append("\"/\": \"\(p)\"") }
        switch c.query {
        case .whole(let q)?: parts.append("\"?\": \"\(q)\"")
        case .items(let items)?: parts.append("\"?\": {" + items.keys.sorted().map { "\($0): \(items[$0]!)" }.joined(separator: ", ") + "}")
        case nil: break
        }
        if let f = c.fragment { parts.append("\"#\": \"\(f)\"") }
        if c.exclude { parts.append("exclude") }
        var text = parts.joined(separator: ", ")
        if let comment = c.comment { text += " (\(comment))" }
        return text
    }

    /// Apple's pattern syntax: `*` = zero or more characters, `?` = exactly one.
    static func wildcardMatch(pattern: String, text: String, caseSensitive: Bool) -> Bool {
        let p = Array(caseSensitive ? pattern : pattern.lowercased())
        let t = Array(caseSensitive ? text : text.lowercased())
        var pi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

// MARK: - Fetching and HTTP checks

public enum AASAFetch {
    /// Accepts `example.com`, `https://example.com/x`, or an entitlement like `applinks:example.com?mode=developer`.
    public static func normalizeDomain(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["applinks:", "webcredentials:", "appclips:", "activitycontinuation:"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if !s.contains("://") { s = "https://" + s }
        guard let host = URLComponents(string: s)?.host?.lowercased(), host.contains(".") else { return nil }
        return host
    }

    /// The file on your own server.
    public static func directURL(for domain: String) -> URL {
        URL(string: "https://\(domain)/.well-known/apple-app-site-association")!
    }

    /// Apple's CDN copy, which is what devices actually download.
    public static func cdnURL(for domain: String) -> URL {
        URL(string: "https://app-site-association.cdn-apple.com/a/v1/\(domain)")!
    }

    /// Checks Apple's hosting requirements on a fetched response.
    public static func checkResponse(requested: URL, final: URL?, statusCode: Int, contentType: String?, byteCount: Int) -> [AASAFile.Issue] {
        var issues: [AASAFile.Issue] = []
        if statusCode != 200 {
            issues.append(.init(severity: .error, message: "The server returned HTTP \(statusCode); it must return 200."))
        }
        if let final, final.absoluteString != requested.absoluteString {
            issues.append(.init(severity: .error, message: "The request was redirected to \(final.absoluteString). Apple doesn't follow redirects for this file."))
        }
        if let type = contentType?.lowercased(), !type.hasPrefix("application/json") {
            issues.append(.init(severity: .warning, message: "Content-Type is \"\(type)\". Serve it as application/json."))
        }
        if byteCount > 128 * 1024 {
            issues.append(.init(severity: .error, message: "The file is \(byteCount / 1024) KB; the limit is 128 KB."))
        }
        return issues
    }
}
