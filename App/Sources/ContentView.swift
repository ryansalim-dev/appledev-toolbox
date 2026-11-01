import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(ToolSection.allCases) { section in
                    Section(section.rawValue) {
                        ForEach(ToolID.allCases.filter { $0.section == section }) { tool in
                            HStack {
                                Label(tool.title, systemImage: tool.systemImage)
                                Spacer()
                                if !tool.isAvailable {
                                    Text("Soon")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(tool)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.notice {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(notice)
                        Spacer()
                        Button("Dismiss") { model.notice = nil }
                            .buttonStyle(.link)
                    }
                    .padding(8)
                    .background(.yellow.opacity(0.15))
                }
                detail(for: model.selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(model.selection?.title ?? "AppleDev Toolbox")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.route(fileURL: url)
            return true
        }
        #if DEBUG
        .task {
            if ScreenshotMode.isEnabled { await ScreenshotMode.run(model) }
        }
        #endif
    }

    @ViewBuilder
    private func detail(for tool: ToolID?) -> some View {
        switch tool {
        case .json: JSONFormatterView()
        case .codable: CodableGeneratorView()
        case .jwt: JWTView()
        case .base64: Base64View()
        case .timestamp: TimestampView()
        case .profiles: ProfilesView()
        case .certificates: CertificatesView()
        case .crashLogs: CrashLogView()
        case .push: PushTesterView()
        case .universalLinks: UniversalLinksView()
        case .plist: PlistView()
        case .privacy: PrivacyCheckerView()
        case .appIcon: AppIconView()
        case nil: ComingSoonView(tool: nil)
        }
    }
}

struct ComingSoonView: View {
    let tool: ToolID?

    var body: some View {
        ContentUnavailableView {
            Label(tool?.title ?? "Pick a tool", systemImage: tool?.systemImage ?? "sidebar.left")
        } description: {
            Text(tool == nil ? "Choose a tool from the sidebar, or paste anything with ⇧⌘V." : "This tool is coming in a later build.")
        }
    }
}
