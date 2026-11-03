import Foundation

enum Greeter {
    static var ticks = 0

    static func start() {
        let message = "hello-from-sample-app"
        print(message) // CI_BREAKPOINT
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            ticks += 1
            print("tick \(ticks)")
        }
    }
}
