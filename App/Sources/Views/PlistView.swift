import AppKit
import SwiftUI
import ToolboxCore
import UniformTypeIdentifiers

struct PlistView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case view = "View"
        case compare = "Compare"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .view

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(8)
            Divider()
            switch mode {
            case .view: PlistViewer()
            case .compare: PlistCompareView()
            }
        }
    }
}

// MARK: - Viewer

struct PlistViewer: View {
    @Environment(AppModel.self) private var model
    @State private var source: BundlePlistSource = .infoPlist
    @State private var resolvedApp: URL?
    @State private var resolvedFor: URL?
    @State private var document: PlistDocument?
    @State private var errorText: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                if model.appBundleURL != nil {
                    Picker("Show", selection: $source) {
                        ForEach(BundlePlistSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                }
                if let document {
                    Text(document.format.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                if isLoading { ProgressView().controlSize(.small) }
                Spacer()
                if let document {
                    Button("Copy as XML") { Clipboard.copy(document.xmlString()) }
                    Button("Copy as JSON") { Clipboard.copy(document.jsonValue().formatted()) }
                }
                Button("Open…") { model.presentOpenPanel() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if let errorText {
                OutputView(text: errorText, isError: true)
            } else if let document {
                PlistOutline(document: document)
            } else if !isLoading {
                ContentUnavailableView {
                    Label("No property list", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Drop a .plist, .entitlements or .xcprivacy file, or an .app or .ipa to see its Info.plist, entitlements, embedded profile and privacy manifest.")
                }
            }
        }
        .task(id: loadKey) { await load() }
    }

    private var title: String {
        model.appBundleURL?.lastPathComponent ?? model.plistItem?.name ?? "Property list"
    }

    /// Changes whenever something to load changes.
    private var loadKey: String {
        [model.appBundleURL?.path ?? "", model.plistItem?.id.uuidString ?? "", source.rawValue].joined(separator: "|")
    }

    private func load() async {
        errorText = nil
        if let bundle = model.appBundleURL {
            isLoading = true
            defer { isLoading = false }
            do {
                // Unzip an .ipa once, not every time the source picker changes.
                let app: URL
                if let resolvedApp, resolvedFor == bundle {
                    app = resolvedApp
                } else {
                    app = try await PlistLoader.resolveApp(bundle)
                    resolvedApp = app
                    resolvedFor = bundle
                }
                document = try await PlistLoader.load(source, app: app)
            } catch {
                document = nil
                errorText = String(describing: error)
            }
        } else if let item = model.plistItem {
            do {
                document = try PlistDocument.parse(item.data)
            } catch {
                document = nil
                errorText = String(describing: error)
            }
        } else {
            document = nil
        }
    }
}

struct PlistOutline: View {
    let document: PlistDocument

    var body: some View {
        List {
            HStack {
                Text("Key").frame(minWidth: 240, alignment: .leading)
                Text("Type").frame(width: 90, alignment: .leading)
                Text("Value")
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            OutlineGroup(document.nodes, children: \.children) { node in
                HStack(alignment: .firstTextBaseline) {
                    Text(node.key).frame(minWidth: 240, alignment: .leading).lineLimit(1)
                    Text(node.type).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Text(node.value)
                        .foregroundStyle(node.children == nil ? .primary : .secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .font(.system(.body, design: .monospaced))
                .contextMenu {
                    Button("Copy Key") { Clipboard.copy(node.key) }
                    Button("Copy Value") { Clipboard.copy(node.value) }
                    Button("Copy Key Path") { Clipboard.copy(node.id) }
                }
            }
        }
    }
}

// MARK: - Compare

struct PlistCompareView: View {
    @State private var oldURL: URL?
    @State private var newURL: URL?
    @State private var changes: [PlistDiff.Change]?
    @State private var errorText: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                slot("Old", url: $oldURL)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                slot("New", url: $newURL)
                if isLoading { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(12)
            Divider()
            if let errorText {
                OutputView(text: errorText, isError: true)
            } else if let changes {
                if changes.isEmpty {
                    ContentUnavailableView("No differences", systemImage: "equal.circle")
                } else {
                    List(Array(changes.enumerated()), id: \.offset) { _, change in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: symbol(change.kind)).foregroundStyle(color(change.kind))
                            Text(change.path).font(.system(.body, design: .monospaced)).frame(minWidth: 260, alignment: .leading)
                            Text(describe(change)).textSelection(.enabled)
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Compare two property lists", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Choose two plists, entitlements files, profiles, or builds (.app / .ipa compare their signed entitlements). Handy for \"why did signing break between these builds?\"")
                }
            }
        }
        .task(id: "\(oldURL?.path ?? "")|\(newURL?.path ?? "")") { await compare() }
    }

    private func slot(_ label: String, url: Binding<URL?>) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Button(url.wrappedValue?.lastPathComponent ?? "Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.treatsFilePackagesAsDirectories = false
                if panel.runModal() == .OK { url.wrappedValue = panel.url }
            }
            .frame(maxWidth: 260)
        }
    }

    private func compare() async {
        guard let oldURL, let newURL else { changes = nil; return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let a = PlistLoader.loadForComparison(oldURL)
            async let b = PlistLoader.loadForComparison(newURL)
            changes = PlistDiff.compare(try await a.root, try await b.root)
            errorText = nil
        } catch {
            changes = nil
            errorText = String(describing: error)
        }
    }

    private func symbol(_ kind: PlistDiff.Change.Kind) -> String {
        switch kind {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .changed: return "pencil.circle.fill"
        }
    }

    private func color(_ kind: PlistDiff.Change.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .changed: return .orange
        }
    }

    private func describe(_ change: PlistDiff.Change) -> String {
        switch change.kind {
        case .added: return change.new ?? ""
        case .removed: return change.old ?? ""
        case .changed: return "\(change.old ?? "") → \(change.new ?? "")"
        }
    }
}
