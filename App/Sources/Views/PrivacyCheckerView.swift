import AppKit
import SwiftUI
import ToolboxCore

struct PrivacyCheckerView: View {
    @State private var target: URL?
    @State private var result: PrivacyScanRunner.Result?
    @State private var errorText: String?
    @State private var isScanning = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Choose Project or App…", action: choose)
                if let target {
                    Text(target.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Button("Rescan") { Task { await scan(target) } }.disabled(isScanning)
                }
                if isScanning { ProgressView().controlSize(.small) }
                Spacer()
                if let result, !result.missingCategories.isEmpty {
                    Button("Copy Manifest Entries") {
                        Clipboard.copy(PrivacyScanRunner.snippet(for: result.missingCategories))
                    }
                    .help("XML for NSPrivacyAccessedAPITypes with the usual reason for each missing category. Check each reason fits your use.")
                }
            }
            .padding(12)
            Divider()

            if let errorText {
                OutputView(text: errorText, isError: true)
            } else if let result {
                report(result)
            } else if !isScanning {
                ContentUnavailableView {
                    Label("Check privacy before you submit", systemImage: "hand.raised")
                } description: {
                    Text("Choose a project folder to scan its source, or a built .app / .ipa to scan its binaries and frameworks. The check finds required-reason APIs without a declared reason, invalid manifest entries, SDKs without manifests, and permission prompts missing their Info.plist usage description.")
                } actions: {
                    Button("Choose…", action: choose)
                }
            }
        }
    }

    private func report(_ result: PrivacyScanRunner.Result) -> some View {
        let errors = result.findings.filter { $0.severity == .error }.count
        let warnings = result.findings.filter { $0.severity == .warning }.count
        return List {
            Section {
                HStack(spacing: 16) {
                    Label(errors == 0 ? "No blocking issues" : "\(errors) issue\(errors == 1 ? "" : "s") to fix",
                          systemImage: errors == 0 ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(errors == 0 ? .green : .red)
                        .font(.headline)
                    if warnings > 0 { Text("\(warnings) warning\(warnings == 1 ? "" : "s")").foregroundStyle(.orange) }
                    Spacer()
                    Text("\(result.scannedFiles) files scanned · manifests: \(result.manifestPaths.isEmpty ? "none" : result.manifestPaths.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Section {
                ForEach(result.findings) { finding in
                    FindingRow(finding: finding)
                }
            } footer: {
                Text("Detection looks for API names, so it can flag code that only mentions them. Each finding lists where it was seen.")
                    .font(.caption)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a project folder, or a built .app or .ipa."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        target = url
        Task { await scan(url) }
    }

    private func scan(_ url: URL) async {
        isScanning = true
        defer { isScanning = false }
        do {
            result = try await PrivacyScanRunner.scan(url)
            errorText = nil
        } catch {
            result = nil
            errorText = String(describing: error)
        }
    }
}

private struct FindingRow: View {
    let finding: PrivacyFinding
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(finding.title, systemImage: icon)
                .foregroundStyle(color)
                .font(.body.bold())
            if !finding.detail.isEmpty {
                Text(finding.detail).font(.callout).textSelection(.enabled)
            }
            if !finding.evidence.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    Text(finding.evidence.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Seen in \(finding.evidence.count) place\(finding.evidence.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch finding.severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private var color: Color {
        switch finding.severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
