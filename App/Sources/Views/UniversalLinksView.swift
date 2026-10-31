import SwiftUI
import ToolboxCore

struct UniversalLinksView: View {
    struct Fetched {
        let label: String
        let requested: URL
        var statusCode: Int?
        var contentType: String?
        var byteCount = 0
        var httpIssues: [AASAFile.Issue] = []
        var file: AASAFile?
        var fileIssues: [AASAFile.Issue] = []
        var error: String?

        var allIssues: [AASAFile.Issue] { httpIssues + fileIssues }
        var isOK: Bool { error == nil && file != nil && !allIssues.contains { $0.severity == .error } }
    }

    @Environment(AppModel.self) private var model
    @State private var direct: Fetched?
    @State private var cdn: Fetched?
    @State private var isChecking = false
    @State private var testURL = ""
    @State private var checkedDomain: String?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                TextField("Domain, URL, or applinks:example.com", text: $model.linksDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await check() } }
                Button("Check") { Task { await check() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(AASAFetch.normalizeDomain(model.linksDomain) == nil || isChecking)
                if isChecking { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()

            if direct == nil && cdn == nil {
                ContentUnavailableView {
                    Label("Check a domain's universal links", systemImage: "link")
                } description: {
                    Text("Fetches apple-app-site-association from your server and from Apple's CDN (what devices actually use), checks it against Apple's rules, and tests which URLs open your app.")
                }
            } else {
                results
            }
        }
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    if let direct { sourceBox(direct) }
                    if let cdn { sourceBox(cdn) }
                }

                if let mismatch = cdnMismatch {
                    Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                if let file = direct?.file ?? cdn?.file {
                    GroupBox("Apps") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(file.details.enumerated()), id: \.offset) { _, detail in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(detail.appIDs.joined(separator: ", ")).bold().textSelection(.enabled)
                                    ForEach(Array(detail.components.enumerated()), id: \.offset) { _, c in
                                        Text("• " + file.describe(c))
                                            .font(.system(.callout, design: .monospaced))
                                            .foregroundStyle(c.exclude ? .secondary : .primary)
                                    }
                                    ForEach(detail.legacyPaths, id: \.self) { path in
                                        Text("• paths: \(path)").font(.system(.callout, design: .monospaced))
                                    }
                                }
                            }
                            if !file.webCredentialsApps.isEmpty {
                                Text("Web credentials: " + file.webCredentialsApps.joined(separator: ", ")).font(.callout)
                            }
                            if !file.appClipsApps.isEmpty {
                                Text("App Clips: " + file.appClipsApps.joined(separator: ", ")).font(.callout)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Test a URL") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("https://\(checkedDomain ?? "example.com")/path?query", text: $testURL)
                                .textFieldStyle(.roundedBorder)
                            if let url = URL(string: testURL), url.host != nil {
                                ForEach(Array(file.match(url).enumerated()), id: \.offset) { _, match in
                                    matchRow(match)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    DisclosureGroup("Raw JSON") {
                        Text(file.raw.formatted())
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text("Tip: on a test device, add ?mode=developer to the associated domain (applinks:example.com?mode=developer) and enable Associated Domains Development in Developer settings to skip Apple's CDN while iterating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func sourceBox(_ f: Fetched) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(f.requested.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let error = f.error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                } else {
                    Text("HTTP \(f.statusCode.map(String.init) ?? "?") · \(f.contentType ?? "no content type") · \(f.byteCount) bytes")
                        .font(.callout)
                    if f.allIssues.isEmpty {
                        Label("Meets Apple's requirements", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    ForEach(Array(f.allIssues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                            .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(f.label, systemImage: f.isOK ? "checkmark.seal.fill" : "exclamationmark.triangle")
        }
    }

    private func matchRow(_ match: AASAFile.Match) -> some View {
        let (symbol, color, text): (String, Color, String) = {
            switch match.outcome {
            case .opensApp: return ("arrow.up.forward.app.fill", .green, "Opens the app")
            case .excluded: return ("safari", .orange, "Excluded, opens in Safari")
            case .noMatch: return ("minus.circle", .secondary, "No rule matches, opens in Safari")
            }
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Label(text, systemImage: symbol).foregroundStyle(color)
            Text(match.appIDs.joined(separator: ", ") + (match.rule.map { " · rule \($0)" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Devices use Apple's CDN copy, so a difference explains "I fixed the file but links still don't work".
    private var cdnMismatch: String? {
        guard let a = direct?.file?.raw, let b = cdn?.file?.raw, a.minified(sortKeys: true) != b.minified(sortKeys: true) else { return nil }
        return "Apple's CDN has a different version than your server. Devices use the CDN copy, which Apple refreshes on its own schedule."
    }

    private func check() async {
        guard let domain = AASAFetch.normalizeDomain(model.linksDomain) else { return }
        isChecking = true
        defer { isChecking = false }
        checkedDomain = domain
        if testURL.isEmpty { testURL = "https://\(domain)/" }
        async let d = fetch(label: "Your server", url: AASAFetch.directURL(for: domain))
        async let c = fetch(label: "Apple CDN", url: AASAFetch.cdnURL(for: domain))
        direct = await d
        cdn = await c
    }

    private func fetch(label: String, url: URL) async -> Fetched {
        var result = Fetched(label: label, requested: url)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("AppleDevToolbox", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            result.statusCode = http?.statusCode
            result.contentType = http?.value(forHTTPHeaderField: "Content-Type")
            result.byteCount = data.count
            result.httpIssues = AASAFetch.checkResponse(
                requested: url, final: response.url, statusCode: http?.statusCode ?? 0,
                contentType: result.contentType, byteCount: data.count
            )
            if http?.statusCode == 200 {
                do {
                    let parsed = try AASAFile.parse(data)
                    result.file = parsed.file
                    result.fileIssues = parsed.issues
                } catch {
                    result.fileIssues = [.init(severity: .error, message: String(describing: error))]
                }
            }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }
}
