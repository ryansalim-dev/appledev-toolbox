import SwiftUI

@main
struct SampleApp: App {
    init() {
        Greeter.start()
    }

    var body: some Scene {
        WindowGroup { Text("Sample") }
    }
}
