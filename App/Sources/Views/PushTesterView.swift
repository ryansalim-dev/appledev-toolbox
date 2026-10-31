import AppKit
import SwiftUI
import ToolboxCore
import UniformTypeIdentifiers

struct PushTesterView: View {
    enum Target: String, CaseIterable, Identifiable {
        case device = "Device (APNs)"
        case simulator = "Simulator"
        var id: String { rawValue }
    }

    struct SendResult: Identifiable {
        let id = UUID()
        let date = Date()
        let target: String
        let success: Bool
        let title: String
        let detail: String
    }

    // Settings remembered between launches. The key itself is never copied; only its path is stored.
    @AppStorage("push.target") private var target: Target = .device
    @AppStorage("push.keyPath") private var keyPath = ""
    @AppStorage("push.keyID") private var keyID = ""
    @AppStorage("push.teamID") private var teamID = ""
    @AppStorage("push.bundleID") private var bundleID = ""
    @AppStorage("push.environment") private var environment: APNsRequest.Environment = .sandbox
    @AppStorage("push.deviceToken") private var deviceToken = ""
    @AppStorage("push.pushType") private var pushType: APNsRequest.PushType = .alert
    @AppStorage("push.priority") private var priority: APNsRequest.Priority = .immediate
    @AppStorage("push.payload") private var payload = APNsTemplates.all().first?.payload ?? "{}"

    @State private var collapseID = ""
    @State private var simulators: [SimulatorPush.Device] = []
    @State private var simulatorUDID = ""
    @State private var isSending = false
    @State private var results: [SendResult] = []
    @State private var tokenCache = APNsTokenCache()

    private var request: APNsRequest {
        APNsRequest(
            environment: environment,
            deviceToken: deviceToken,
            bundleID: bundleID,
            pushType: pushType,
            priority: priority,
            payload: payload,
            collapseID: collapseID.isEmpty ? nil : collapseID
        )
    }

    /// Validation issues relevant to the current target (the simulator doesn't need a token).
    private var issues: [APNsRequest.Issue] {
        var list = request.validate()
        if target == .simulator {
            list.removeAll { $0.message.contains("device token") || $0.message.contains("Device tokens") }
            if simulatorUDID.isEmpty { list.insert(.init(severity: .error, message: "Boot a Simulator and pick it."), at: 0) }
        } else {
            if keyPath.isEmpty { list.insert(.init(severity: .error, message: "Choose your APNs .p8 key."), at: 0) }
            if keyID.count != 10 { list.append(.init(severity: .error, message: "The Key ID is 10 characters (from the developer portal or the AuthKey_ file name).")) }
            if teamID.count != 10 { list.append(.init(severity: .error, message: "The Team ID is 10 characters.")) }
        }
        return list
    }

    var body: some View {
        HSplitView {
            settingsForm
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
            VStack(spacing: 0) {
                payloadEditor
                Divider()
                resultsList
                    .frame(minHeight: 120, idealHeight: 180)
            }
            .frame(minWidth: 380)
        }
        .task { await reloadSimulators() }
    }

    // MARK: - Settings

    private var settingsForm: some View {
        Form {
            Section {
                Picker("Send to", selection: $target) {
                    ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if target == .device {
                Section("Authentication (token-based)") {
                    LabeledContent("Key (.p8)") {
                        HStack {
                            Text(keyPath.isEmpty ? "None" : (keyPath as NSString).lastPathComponent)
                                .foregroundStyle(keyPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…", action: chooseKey)
                        }
                    }
                    TextField("Key ID", text: $keyID)
                    TextField("Team ID", text: $teamID)
                }
                Section("Destination") {
                    Picker("Environment", selection: $environment) {
                        ForEach(APNsRequest.Environment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Bundle ID", text: $bundleID)
                    TextField("Device token", text: $deviceToken, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...4)
                    Text("Debug builds from Xcode use Sandbox. TestFlight and App Store builds use Production.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Destination") {
                    Picker("Simulator", selection: $simulatorUDID) {
                        if simulators.isEmpty { Text("No booted Simulators").tag("") }
                        ForEach(simulators) { Text("\($0.name) (\($0.runtime))").tag($0.udid) }
                    }
                    Button("Refresh") { Task { await reloadSimulators() } }
                    TextField("Bundle ID", text: $bundleID)
                }
            }

            Section("Options") {
                Picker("Push type", selection: $pushType) {
                    ForEach(APNsRequest.PushType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Priority", selection: $priority) {
                    Text("10 (immediate)").tag(APNsRequest.Priority.immediate)
                    Text("5 (power considerate)").tag(APNsRequest.Priority.powerConsiderate)
                    Text("1 (low)").tag(APNsRequest.Priority.low)
                }
                TextField("Collapse ID (optional)", text: $collapseID)
                if target == .device {
                    LabeledContent("Topic", value: request.topic.isEmpty ? "—" : request.topic)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Payload

    private var payloadEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Menu("Templates") {
                    ForEach(APNsTemplates.all()) { template in
                        Button(template.name) {
                            payload = template.payload
                            pushType = template.pushType
                            priority = template.priority
                        }
                    }
                }
                .fixedSize()
                Button("Format") {
                    if let value = try? JSONParser.parse(payload) { payload = value.formatted() }
                }
                Spacer()
                Text("\(request.body.count) / \(pushType.maxPayloadBytes) bytes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(request.body.count > pushType.maxPayloadBytes ? .red : .secondary)
                Button {
                    Task { await send() }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isSending || issues.contains { $0.severity == .error })
                if isSending { ProgressView().controlSize(.small) }
            }
            .padding(8)
            Divider()
            CodeEditor(text: $payload, placeholder: "JSON payload")
            if !issues.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                            .font(.callout)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        Group {
            if results.isEmpty {
                ContentUnavailableView("No pushes sent yet", systemImage: "bell.badge",
                                       description: Text("Results from APNs or the Simulator appear here. ⌘↩ sends."))
            } else {
                List(results) { result in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.success ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(result.title).bold()
                                Text(result.target).foregroundStyle(.secondary)
                                Spacer()
                                Text(result.date, style: .time).foregroundStyle(.secondary).font(.caption)
                            }
                            Text(result.detail)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.message = "Choose the AuthKey_XXXXXXXXXX.p8 file you downloaded from the developer portal."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keyPath = url.path
        if let id = APNsSigningKey.keyID(fromFileName: url.lastPathComponent) { keyID = id }
    }

    private func reloadSimulators() async {
        guard let output = try? await CommandRunner.xcrun(SimulatorPush.listArguments) else {
            simulators = []
            return
        }
        simulators = SimulatorPush.parseDevices(output).filter(\.isBooted)
        if !simulators.contains(where: { $0.udid == simulatorUDID }) {
            simulatorUDID = simulators.first?.udid ?? ""
        }
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        let result: SendResult
        switch target {
        case .device: result = await sendToDevice(request)
        case .simulator: result = await sendToSimulator(request)
        }
        results.insert(result, at: 0)
        if results.count > 50 { results.removeLast(results.count - 50) }
    }

    private func sendToDevice(_ request: APNsRequest) async -> SendResult {
        let targetName = "\(environment.rawValue) · …\(request.normalizedDeviceToken.suffix(6))"
        do {
            let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
            let key = try APNsSigningKey(pem: pem, keyID: keyID, teamID: teamID)
            let jwt = try tokenCache.token(for: key)

            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = request.body
            for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            urlRequest.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")

            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return SendResult(target: targetName, success: false, title: "No HTTP response", detail: "")
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name] = value }
            }
            let apns = APNsResponse(statusCode: http.statusCode, headers: headers, body: data)
            var detail = apns.explanation
            if let id = apns.apnsUniqueID {
                detail += "\nLook it up in the Push Notifications Console with unique ID \(id)."
            } else if let id = apns.apnsID {
                detail += "\napns-id: \(id)"
            }
            if let since = apns.invalidSince {
                detail += "\nToken invalid since \(since.formatted(date: .abbreviated, time: .shortened))."
            }
            return SendResult(
                target: targetName,
                success: apns.isSuccess,
                title: apns.isSuccess ? "200 OK · \(elapsed) ms" : "\(apns.statusCode) \(apns.reason ?? "")",
                detail: detail
            )
        } catch {
            return SendResult(target: targetName, success: false, title: "Couldn't send", detail: String(describing: error))
        }
    }

    private func sendToSimulator(_ request: APNsRequest) async -> SendResult {
        let name = simulators.first(where: { $0.udid == simulatorUDID })?.name ?? "Simulator"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString).json")
        do {
            try request.body.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            _ = try await CommandRunner.xcrun(SimulatorPush.pushArguments(
                deviceUDID: simulatorUDID,
                bundleID: bundleID.trimmingCharacters(in: .whitespaces),
                payloadPath: file.path
            ))
            return SendResult(target: name, success: true, title: "Delivered to Simulator",
                              detail: "simctl accepted the payload. If nothing appears, check the app has notification permission.")
        } catch {
            return SendResult(target: name, success: false, title: "simctl failed", detail: String(describing: error))
        }
    }
}
