import SwiftUI

@main
struct AppleDevToolboxApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste and Detect") { model.pasteAndDetect() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
    }
}
