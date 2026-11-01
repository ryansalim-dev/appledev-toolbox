import AppKit
import SwiftUI
import ToolboxCore
import UniformTypeIdentifiers

struct AppIconView: View {
    @State private var images: [AppIconSet.Variant: CGImage] = [:]
    @State private var names: [AppIconSet.Variant: String] = [:]
    @AppStorage("icon.iOS") private var includeIOS = true
    @AppStorage("icon.macOS") private var includeMac = false
    @AppStorage("icon.watchOS") private var includeWatch = false
    @State private var background = Color.white
    @State private var status: String?

    private var platforms: Set<AppIconSet.Platform> {
        var set: Set<AppIconSet.Platform> = []
        if includeIOS { set.insert(.iOS) }
        if includeMac { set.insert(.macOS) }
        if includeWatch { set.insert(.watchOS) }
        return set
    }

    private var issues: [(AppIconSet.Variant, AppIconSet.SourceIssue)] {
        AppIconSet.Variant.allCases.flatMap { variant -> [(AppIconSet.Variant, AppIconSet.SourceIssue)] in
            guard let image = images[variant] else { return [] }
            return AppIconSet.validateSource(width: image.width, height: image.height, hasAlpha: IconRenderer.hasAlpha(image),
                                             platforms: platforms, variant: variant).map { (variant, $0) }
        }
    }

    var body: some View {
        HSplitView {
            Form {
                Section("Source images (1024×1024 PNG)") {
                    imagePicker(.standard, label: "Icon")
                    if includeIOS {
                        imagePicker(.dark, label: "Dark (optional)")
                        imagePicker(.tinted, label: "Tinted (optional)")
                    }
                }
                Section("Platforms") {
                    Toggle("iOS / iPadOS (single 1024 size)", isOn: $includeIOS)
                    Toggle("macOS (16–1024 px)", isOn: $includeMac)
                    Toggle("watchOS (single 1024 size)", isOn: $includeWatch)
                }
                Section {
                    ColorPicker("Background for transparent areas", selection: $background, supportsOpacity: false)
                } footer: {
                    Text("iOS and watchOS icons can't be transparent; transparent pixels are filled with this color. macOS icons keep their transparency, so design them on Apple's macOS icon grid.")
                }
                Section {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, entry in
                        Label("\(entry.0 == .standard ? "" : "\(entry.0.rawValue.capitalized): ")\(entry.1.message)",
                              systemImage: entry.1.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(entry.1.severity == .error ? .red : .orange)
                    }
                    Button("Export AppIcon.appiconset…", action: export)
                        .buttonStyle(.borderedProminent)
                        .disabled(images[.standard] == nil || platforms.isEmpty || issues.contains { $0.1.severity == .error })
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 340, idealWidth: 380)

            preview
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func imagePicker(_ variant: AppIconSet.Variant, label: String) -> some View {
        LabeledContent(label) {
            HStack {
                Text(names[variant] ?? "None").foregroundStyle(names[variant] == nil ? .secondary : .primary).lineLimit(1)
                Button("Choose…") { choose(variant) }
                if images[variant] != nil, variant != .standard {
                    Button("Clear") { images[variant] = nil; names[variant] = nil }
                }
            }
        }
    }

    private var preview: some View {
        ScrollView {
            if let source = images[.standard] {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Preview").font(.headline)
                    HStack(alignment: .bottom, spacing: 24) {
                        ForEach([180, 120, 60], id: \.self) { size in
                            VStack {
                                iconPreview(images[.standard] ?? source, size: CGFloat(size))
                                Text("\(size) px").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let dark = images[.dark] {
                        HStack(spacing: 16) {
                            iconPreview(dark, size: 120)
                                .padding(16)
                                .background(.black, in: RoundedRectangle(cornerRadius: 12))
                            Text("Dark appearance").foregroundStyle(.secondary)
                        }
                    }
                    if includeMac {
                        HStack(spacing: 16) {
                            Image(decorative: source, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 128, height: 128)
                            Text("macOS (shown unmasked)").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("No icon yet", systemImage: "app.dashed",
                                       description: Text("Choose a 1024×1024 image to preview it with the iOS mask and export an asset catalog icon set."))
                    .frame(minHeight: 400)
            }
        }
    }

    /// iOS-style squircle mask (continuous corners at ~22.4% of the size).
    private func iconPreview(_ image: CGImage, size: CGFloat) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }

    private func choose(_ variant: AppIconSet.Variant) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = IconRenderer.load(url) else {
            status = "Couldn't read \(url.lastPathComponent)."
            return
        }
        images[variant] = image
        names[variant] = url.lastPathComponent
        status = nil
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder, such as your Assets.xcassets. AppIcon.appiconset is created (or replaced) inside it."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var variants: Set<AppIconSet.Variant> = [.standard]
        if images[.dark] != nil { variants.insert(.dark) }
        if images[.tinted] != nil { variants.insert(.tinted) }
        let plan = AppIconSet.plan(platforms: platforms, variants: variants)
        let cgBackground = NSColor(background).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1)
        do {
            let set = try IconRenderer.writeIconSet(plan: plan, sources: images, background: cgBackground, into: folder)
            status = "Wrote \(plan.renditions.count) images to \(set.path)."
            NSWorkspace.shared.activateFileViewerSelecting([set])
        } catch {
            status = String(describing: error)
        }
    }
}
