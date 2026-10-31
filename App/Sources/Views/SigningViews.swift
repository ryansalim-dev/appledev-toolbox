import AppKit
import SwiftUI
import ToolboxCore

// MARK: - Provisioning profiles

struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var library = ProfileLibrary(profiles: [], failures: [])
    @State private var selection: ProvisioningProfile.ID?
    @State private var search = ""
    @State private var confirmCleanup = false
    @State private var cleanupCandidates: [ProvisioningProfile] = []

    private var filtered: [ProvisioningProfile] {
        var all = library.profiles
        if let opened = model.openedProfile, !all.contains(where: { $0.uuid == opened.uuid }) {
            all.insert(opened, at: 0)
        }
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.applicationIdentifier ?? "").localizedCaseInsensitiveContains(search)
                || ($0.teamName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Table(filtered, selection: $selection) {
                    TableColumn("Name") { profile in
                        Text(profile.name).foregroundStyle(profile.isExpired() ? .secondary : .primary)
                    }
                    TableColumn("Type") { Text($0.kind.rawValue) }
                        .width(min: 70, ideal: 90)
                    TableColumn("App ID") { Text($0.bundleIdentifier ?? "—") }
                    TableColumn("Team") { Text($0.teamName ?? "—") }
                    TableColumn("Expires") { profile in
                        ExpiryText(date: profile.expirationDate)
                    }
                    .width(min: 90, ideal: 110)
                }
                Divider()
                HStack {
                    Text("\(library.profiles.count) installed · \(library.expired().count) expired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clean Up…") {
                        cleanupCandidates = uniqueByUUID(library.expired() + library.superseded())
                        confirmCleanup = true
                    }
                    .disabled(library.expired().isEmpty && library.superseded().isEmpty)
                    Button("Reload", action: reload)
                }
                .padding(8)
            }
            .frame(minWidth: 420)

            Group {
                if let profile = filtered.first(where: { $0.id == selection }) {
                    ProfileDetailView(profile: profile)
                } else {
                    ContentUnavailableView("No profile selected", systemImage: "doc.badge.gearshape",
                                           description: Text("Select a profile, or drop a .mobileprovision anywhere in the window."))
                }
            }
            .frame(minWidth: 320)
        }
        .searchable(text: $search, placement: .toolbar)
        .onAppear(perform: reload)
        .onChange(of: model.openedProfile) { _, opened in selection = opened?.id }
        .confirmationDialog(
            "Move \(cleanupCandidates.count) profiles to the Trash?",
            isPresented: $confirmCleanup
        ) {
            Button("Move to Trash", role: .destructive) { moveToTrash(cleanupCandidates) }
        } message: {
            Text("These are expired, or older copies of a profile you have a newer version of. Xcode downloads profiles again when it needs them.")
        }
    }

    private func reload() {
        library = ProfileLibrary.load(from: ProfileLibrary.defaultDirectories())
        if selection == nil { selection = model.openedProfile?.id }
    }

    private func uniqueByUUID(_ profiles: [ProvisioningProfile]) -> [ProvisioningProfile] {
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.uuid).inserted }
    }

    private func moveToTrash(_ profiles: [ProvisioningProfile]) {
        let urls = profiles.compactMap(\.fileURL)
        NSWorkspace.shared.recycle(urls) { _, _ in
            Task { @MainActor in reload() }
        }
    }
}

struct ProfileDetailView: View {
    let profile: ProvisioningProfile
    /// DER data of certificates this Mac can sign with (loaded once; the Keychain query isn't free).
    @State private var signableDERs: Set<Data> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.title2).bold()
                    Text(profile.uuid).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    InfoRow(label: "Type", value: profile.kind.rawValue)
                    InfoRow(label: "App ID", value: profile.applicationIdentifier)
                    InfoRow(label: "App ID name", value: profile.appIDName)
                    InfoRow(label: "Team", value: [profile.teamName, profile.teamIdentifiers.first.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                    InfoRow(label: "Platforms", value: profile.platforms.joined(separator: ", "))
                    InfoRow(label: "Created", value: profile.creationDate?.formatted(date: .abbreviated, time: .shortened))
                    InfoRow(label: "Expires", value: expiryDescription, valueColor: profile.isExpired() ? .red : .primary)
                    InfoRow(label: "Xcode managed", value: profile.isXcodeManaged ? "Yes" : "No")
                    if let url = profile.fileURL {
                        GridRow {
                            Text("File").foregroundStyle(.secondary)
                            Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .buttonStyle(.link)
                        }
                    }
                }

                GroupBox("Entitlements") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(profile.entitlements.keys.sorted(), id: \.self) { key in
                            InfoRow(label: key, value: profile.entitlements[key]?.displayString)
                        }
                    }
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Certificates (\(profile.developerCertificates.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(profile.developerCertificates.compactMap(CertificateInspector.summary(der:))) { cert in
                            CertificateRow(certificate: cert, inKeychain: signableDERs.contains(cert.der))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if profile.provisionsAllDevices {
                    GroupBox("Devices") { Text("All devices (Enterprise)").frame(maxWidth: .infinity, alignment: .leading) }
                } else if !profile.provisionedDevices.isEmpty {
                    GroupBox("Devices (\(profile.provisionedDevices.count))") {
                        Text(profile.provisionedDevices.joined(separator: "\n"))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .task(id: profile.uuid) {
            signableDERs = Set(CertificateInspector.keychainSigningCertificates().filter(\.hasPrivateKey).map(\.der))
        }
    }

    private var expiryDescription: String {
        let days = profile.daysUntilExpiry()
        let date = profile.expirationDate.formatted(date: .abbreviated, time: .shortened)
        if days < 0 { return "\(date) (expired)" }
        return "\(date) (\(days) day\(days == 1 ? "" : "s") left)"
    }
}

// MARK: - Certificates

struct CertificatesView: View {
    @State private var certificates: [CertificateSummary] = []

    var body: some View {
        VStack(spacing: 0) {
            if certificates.isEmpty {
                ContentUnavailableView("No signing certificates", systemImage: "checkmark.seal",
                                       description: Text("Apple Development and Distribution certificates in your Keychain show up here."))
            } else {
                List(certificates) { cert in
                    CertificateRow(certificate: cert, inKeychain: cert.hasPrivateKey)
                }
            }
            Divider()
            HStack {
                Text("A certificate without its private key can't be used to sign on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reload", action: reload)
            }
            .padding(8)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        certificates = CertificateInspector.keychainSigningCertificates()
    }
}

struct CertificateRow: View {
    let certificate: CertificateSummary
    /// Whether this Mac can sign with it (certificate + private key in the Keychain).
    let inKeychain: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: inKeychain ? "key.fill" : "key")
                .foregroundStyle(inKeychain ? .green : .secondary)
                .help(inKeychain ? "Private key is in your Keychain" : "Private key not found on this Mac")
            VStack(alignment: .leading, spacing: 2) {
                Text(certificate.commonName)
                if let expires = certificate.expiresAt {
                    ExpiryText(date: expires).font(.caption)
                }
            }
        }
    }
}

struct ExpiryText: View {
    let date: Date

    var body: some View {
        let days = Int((date.timeIntervalSinceNow / 86_400).rounded(.down))
        Text(days < 0 ? "Expired" : (days == 0 ? "Today" : "\(days) days"))
            .foregroundStyle(days < 0 ? .red : (days < 30 ? .orange : .primary))
            .help(date.formatted(date: .long, time: .shortened))
    }
}
