import AppKit
import SwiftUI

/// Monospaced, editable text area for tool input.
struct CodeEditor: View {
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Read-only, selectable monospaced output with a copy button.
struct OutputView: View {
    let text: String
    var isError = false

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isError ? Color.red : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) {
            if !text.isEmpty && !isError {
                CopyButton(text: text).padding(8)
            }
        }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Input on the left, output on the right, controls on top.
struct SplitToolLayout<Controls: View, Input: View, Output: View>: View {
    @ViewBuilder var controls: Controls
    @ViewBuilder var input: Input
    @ViewBuilder var output: Output

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) { controls }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            HSplitView {
                input.frame(minWidth: 250)
                output.frame(minWidth: 250)
            }
        }
    }
}

/// A two-column label/value row for summary grids.
struct InfoRow: View {
    let label: String
    let value: String?
    var valueColor: Color = .primary

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value ?? "—")
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }
}
