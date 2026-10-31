import AppKit
import SwiftUI
import ToolboxCore
import UniformTypeIdentifiers

struct CrashLogView: View {
    @Environment(AppModel.self) private var model
    @State private var resolved: [UInt64: ResolvedSymbol] = [:]
    @State private var dsymFolders: [URL] = []
    @State private var isSymbolicating = false
    @State private var status: String?
    @State private var showRawJSON = false

    private var parsed: Result<CrashReport, Error>? {
        let text = model.crashLogText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Result { try CrashReportParser.parse(text) }
    }

    var body: some View {
        Group {
            switch parsed {
            case nil:
                emptyState
            case .failure(let error)?:
                OutputView(text: String(describing: error), isError: true)
            case .success(let report)?:
                reportView(report)
            }
        }
        .onChange(of: model.crashLogText) {
            resolved = [:]
            status = nil
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No crash log", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Drop an .ips file anywhere in the window, paste its contents with ⇧⌘V, or open one.")
        } actions: {
            Button("Open Crash Log…") { openIPS(startingIn: nil) }
            Button("Browse This Mac's Crash Reports…") {
                openIPS(startingIn: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true))
            }
        }
    }

    // MARK: - Report

    private func reportView(_ report: CrashReport) -> some View {
        VStack(spacing: 0) {
            summary(report)
                .padding(12)
            Divider()
            HStack(spacing: 10) {
                Button {
                    Task { await symbolicate(report) }
                } label: {
                    Label("Symbolicate", systemImage: "wand.and.stars")
                }
                .disabled(isSymbolicating || Symbolication.requests(for: report).isEmpty)
                .help("Finds matching dSYMs with Spotlight and in folders you add, then runs atos.")

                Button("Add dSYM Folder…", action: addDSYMFolder)
                if isSymbolicating { ProgressView().controlSize(.small) }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Toggle("Raw JSON", isOn: $showRawJSON).toggleStyle(.button)
                Button("Save as .crash…") { save(CrashReportFormatter.text(for: report, resolved: resolved), name: report.appName) }
                Button("Close") { model.crashLogText = ""; model.crashLogURL = nil }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if showRawJSON {
                OutputView(text: report.rawHeader.formatted() + "\n\n" + (report.rawBody?.formatted() ?? ""))
            } else {
                OutputView(text: CrashReportFormatter.text(for: report, resolved: resolved))
            }
        }
    }

    private func summary(_ report: CrashReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.appName ?? report.processName ?? "Unknown app").font(.title2).bold()
                Text([report.appVersion, report.buildVersion.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                    .foregroundStyle(.secondary)
                Spacer()
                if let url = model.crashLogURL {
                    Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                InfoRow(label: "Exception", value: [report.exception?.type, report.exception?.signal.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "),
                        valueColor: .red)
                InfoRow(label: "Crashed thread", value: report.crashedThread.map { t in
                    "Thread \(t.index)" + (t.queue.map { " · \($0)" } ?? "") + (t.name.map { " · \($0)" } ?? "")
                })
                InfoRow(label: "Device", value: [report.hardwareModel, report.osVersion].compactMap { $0 }.joined(separator: " · "))
                InfoRow(label: "When", value: report.captureTime)
            }
            ForEach(report.applicationMessages, id: \.self) { message in
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if !report.isCrash {
                Text("This report type (\(report.bugType ?? "unknown")) isn't a standard crash; some fields may be missing.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    private func symbolicate(_ report: CrashReport) async {
        isSymbolicating = true
        status = "Looking for dSYMs…"
        let outcome = await Symbolicator(extraSearchFolders: dsymFolders).symbolicate(report)
        resolved.merge(outcome.resolved) { _, new in new }
        isSymbolicating = false

        var parts = ["Resolved \(outcome.resolved.count) frame\(outcome.resolved.count == 1 ? "" : "s")."]
        if !outcome.missing.isEmpty { parts.append("No dSYM for: " + outcome.missing.joined(separator: ", ") + ".") }
        if !outcome.errors.isEmpty { parts.append(outcome.errors.joined(separator: "; ")) }
        status = parts.joined(separator: " ")
    }

    private func addDSYMFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a folder that contains dSYMs (for example an .xcarchive), or a .dSYM bundle."
        if panel.runModal() == .OK {
            dsymFolders += panel.urls
            status = "Will also search: " + dsymFolders.map(\.lastPathComponent).joined(separator: ", ")
        }
    }

    private func openIPS(startingIn directory: URL?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let directory { panel.directoryURL = directory }
        if let ips = UTType(filenameExtension: "ips") { panel.allowedContentTypes = [ips, .json, .plainText] }
        if panel.runModal() == .OK, let url = panel.url {
            model.route(fileURL: url)
        }
    }

    private func save(_ text: String, name: String?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (name ?? "Crash") + ".crash"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                status = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }
}
