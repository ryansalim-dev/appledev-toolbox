import SwiftUI
import ToolboxCore

// MARK: - JSON formatter

struct JSONFormatterView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("json.indent") private var indent = 2
    @AppStorage("json.sortKeys") private var sortKeys = false
    @AppStorage("json.minify") private var minify = false

    var body: some View {
        @Bindable var model = model
        SplitToolLayout {
            Picker("Indent", selection: $indent) {
                Text("2 spaces").tag(2)
                Text("4 spaces").tag(4)
            }
            .fixedSize()
            .disabled(minify)
            Toggle("Sort keys", isOn: $sortKeys)
            Toggle("Minify", isOn: $minify)
            Spacer()
            Button("Clear") { model.jsonInput = "" }
        } input: {
            CodeEditor(text: $model.jsonInput, placeholder: "Paste JSON here")
        } output: {
            let result = format(model.jsonInput)
            OutputView(text: result.text, isError: result.isError)
        }
    }

    private func format(_ input: String) -> (text: String, isError: Bool) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ("", false) }
        do {
            let value = try JSONParser.parse(input)
            return (minify ? value.minified(sortKeys: sortKeys) : value.formatted(indent: indent, sortKeys: sortKeys), false)
        } catch {
            return (String(describing: error), true)
        }
    }
}

// MARK: - JSON → Codable

struct CodableGeneratorView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("codable.rootName") private var rootName = "Root"
    @AppStorage("codable.hashable") private var hashable = false
    @AppStorage("codable.sendable") private var sendable = true
    @AppStorage("codable.useVar") private var useVar = false

    var body: some View {
        @Bindable var model = model
        SplitToolLayout {
            TextField("Root type", text: $rootName)
                .frame(width: 140)
            Toggle("Hashable", isOn: $hashable)
            Toggle("Sendable", isOn: $sendable)
            Toggle("Use var", isOn: $useVar)
            Spacer()
            Button("Use JSON from Formatter") { model.codableInput = model.jsonInput }
                .disabled(model.jsonInput.isEmpty)
        } input: {
            CodeEditor(text: $model.codableInput, placeholder: "Paste a JSON sample. Arrays of objects are merged, so include a few elements.")
        } output: {
            let result = generate(model.codableInput)
            OutputView(text: result.text, isError: result.isError)
        }
    }

    private func generate(_ input: String) -> (text: String, isError: Bool) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ("", false) }
        var conformances = ["Codable"]
        if hashable { conformances.append("Hashable") }
        if sendable { conformances.append("Sendable") }
        do {
            let output = try CodableGenerator.generate(
                from: input,
                options: .init(rootName: rootName, conformances: conformances, useVar: useVar)
            )
            return (output, false)
        } catch {
            return (String(describing: error), true)
        }
    }
}

// MARK: - JWT

struct JWTView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HSplitView {
            CodeEditor(text: $model.jwtInput, placeholder: "Paste a JWT (with or without \"Bearer \")")
                .frame(minWidth: 250)
            Group {
                if model.jwtInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("No token", systemImage: "key", description: Text("Paste a token on the left."))
                } else {
                    switch Result(catching: { try JWTDecoder.decode(model.jwtInput) }) {
                    case .success(let jwt): decoded(jwt)
                    case .failure(let error): OutputView(text: String(describing: error), isError: true)
                    }
                }
            }
            .frame(minWidth: 300)
        }
    }

    private func decoded(_ jwt: DecodedJWT) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    InfoRow(label: "Algorithm", value: jwt.algorithm)
                    InfoRow(label: "Key ID", value: jwt.keyID)
                    InfoRow(label: "Issuer", value: jwt.issuer)
                    InfoRow(label: "Subject", value: jwt.subject)
                    InfoRow(label: "Audience", value: jwt.audience.isEmpty ? nil : jwt.audience.joined(separator: ", "))
                    InfoRow(label: "Issued", value: jwt.issuedAt.map(describe))
                    InfoRow(label: "Not before", value: jwt.notBefore.map(describe))
                    InfoRow(
                        label: "Expires",
                        value: jwt.expiresAt.map { describe($0) + (jwt.isExpired() == true ? "  (expired)" : "") },
                        valueColor: jwt.isExpired() == true ? .red : .primary
                    )
                }
                section("Header", jwt.header.formatted())
                section("Payload", jwt.payload.formatted())
                Text("The signature is shown but not verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, _ json: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                CopyButton(text: json)
            }
            Text(json)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func describe(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard) + "  ·  " + TimestampTool.relativeDescription(of: date, now: Date())
    }
}

// MARK: - Base64

struct Base64View: View {
    enum Mode: String, CaseIterable { case decode = "Decode", encode = "Encode" }

    @Environment(AppModel.self) private var model
    @AppStorage("base64.mode") private var mode: Mode = .decode
    @AppStorage("base64.urlSafe") private var urlSafe = false

    var body: some View {
        @Bindable var model = model
        SplitToolLayout {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Toggle("URL-safe", isOn: $urlSafe)
                .disabled(mode == .decode)
            Spacer()
            Button("Clear") { model.base64Input = "" }
        } input: {
            CodeEditor(text: $model.base64Input, placeholder: mode == .decode ? "Paste Base64 (standard or URL-safe)" : "Type text to encode")
        } output: {
            let result = convert(model.base64Input)
            OutputView(text: result.text, isError: result.isError)
        }
    }

    private func convert(_ input: String) -> (text: String, isError: Bool) {
        guard !input.isEmpty else { return ("", false) }
        switch mode {
        case .encode:
            return (Base64Tool.encode(input, urlSafe: urlSafe, padded: !urlSafe), false)
        case .decode:
            do {
                let data = try Base64Tool.decode(input)
                if let text = String(data: data, encoding: .utf8) { return (text, false) }
                return ("Binary data, \(data.count) bytes:\n\n" + Base64Tool.hexDump(data), false)
            } catch {
                return (String(describing: error), true)
            }
        }
    }
}

// MARK: - Timestamps

struct TimestampView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("Unix timestamp (s, ms, µs, ns) or ISO 8601 date", text: $model.timestampInput)
                    .font(.system(.title3, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button("Now") { model.timestampInput = String(Int(Date().timeIntervalSince1970)) }
            }

            if let conversion = TimestampTool.parse(model.timestampInput) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        InfoRow(label: "Interpreted as", value: conversion.detectedUnit?.rawValue ?? "ISO 8601 date")
                        InfoRow(label: "Seconds", value: String(conversion.seconds))
                        InfoRow(label: "Milliseconds", value: String(conversion.milliseconds))
                        InfoRow(label: "UTC", value: conversion.iso8601UTC)
                        InfoRow(label: "Local (\(TimeZone.current.identifier))", value: conversion.iso8601(in: .current))
                        InfoRow(label: "Relative", value: conversion.relative(to: context.date))
                    }
                    .font(.system(.body, design: .monospaced))
                }
            } else if !model.timestampInput.isEmpty {
                Text("Not a timestamp or ISO 8601 date.").foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
    }
}
