#if DEBUG
import AppKit
import SwiftUI
import ToolboxCore

/// Debug-only mode that seeds sample input, visits every tool, and saves a PNG of the
/// window for each one, in light and dark appearance. Used by the Screenshots CI job.
///
/// Enable it by launching the app with `TOOLBOX_SCREENSHOT_DIR=/path/to/output`.
/// `TOOLBOX_FIXTURES_DIR` can point at `Packages/ToolboxCore/Tests/ToolboxCoreTests/Fixtures`
/// so the crash log and provisioning profile tools show real content.
@MainActor
enum ScreenshotMode {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["TOOLBOX_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var isEnabled: Bool { outputDirectory != nil }

    static func run(_ model: AppModel) async {
        guard let output = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        seed(model)
        try? await Task.sleep(for: .seconds(1))

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            print("screenshot: no window")
            exit(1)
        }
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for tool in ToolID.allCases {
                model.selection = tool
                try? await Task.sleep(for: .seconds(1.5))
                let name = "\(tool.rawValue)-\(suffix)"
                let url = output.appendingPathComponent("\(name).png")
                if !screencapture(window, to: url) { capture(window, to: url) }
            }
        }
        print("screenshot: done")
        exit(0)
    }

    // MARK: - Sample input

    private static func seed(_ model: AppModel) {
        model.jsonInput = """
        {"id":42,"name":"AppleDev Toolbox","price":39.0,"platforms":["macOS"],"owner":{"login":"jane","verified":true},"tags":["json","jwt","plist"],"releasedAt":"2026-11-01T09:00:00Z"}
        """
        model.codableInput = """
        [
          {"id": 1, "title": "Fix crash on launch", "isDone": false, "assignee": {"name": "Jane", "email": "jane@example.com"}, "labels": ["bug"]},
          {"id": 2, "title": "Ship 1.0", "isDone": true, "assignee": null, "labels": [], "dueDate": "2026-12-01"}
        ]
        """
        model.jwtInput = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkphbmUgQXBwbGVzZWVkIiwiaXNzIjoiaHR0cHM6Ly9hdXRoLmV4YW1wbGUuY29tIiwiaWF0IjoxNzYxOTU1MjAwLCJleHAiOjE4OTM0NTYwMDAsInNjb3BlIjoicmVhZCB3cml0ZSJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        model.base64Input = "SGVsbG8gZnJvbSBBcHBsZURldiBUb29sYm94IQ=="
        model.timestampInput = "1761987600"
        model.linksDomain = "example.com"
        model.plistItem = AppModel.PlistItem(name: "Info.plist", data: Data(samplePlist.utf8))

        if let fixtures = ProcessInfo.processInfo.environment["TOOLBOX_FIXTURES_DIR"] {
            let dir = URL(fileURLWithPath: fixtures, isDirectory: true)
            if let crash = try? String(contentsOf: dir.appendingPathComponent("crash.ips"), encoding: .utf8) {
                model.crashLogText = crash
            }
            let profileURL = dir.appendingPathComponent("development.mobileprovision")
            if let data = try? Data(contentsOf: profileURL) {
                model.openedProfile = try? ProvisioningProfile.parse(data, fileURL: profileURL)
            }
        }
    }

    private static let samplePlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key><string>com.example.Sample</string>
        <key>CFBundleDisplayName</key><string>Sample</string>
        <key>CFBundleShortVersionString</key><string>1.4.0</string>
        <key>CFBundleVersion</key><string>212</string>
        <key>LSRequiresIPhoneOS</key><true/>
        <key>MinimumOSVersion</key><string>17.0</string>
        <key>NSCameraUsageDescription</key><string>Scan QR codes to pair devices.</string>
        <key>UIBackgroundModes</key><array><string>remote-notification</string><string>fetch</string></array>
        <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
    </dict>
    </plist>
    """

    // MARK: - Capture

    /// Renders the window's frame view (including the title bar) without needing screen
    /// recording permission. Vibrant materials such as the sidebar render blank.
    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    /// Real on-screen capture of the window, which keeps the sidebar's vibrancy. Needs
    /// screen recording permission, so it may fail; the cached rendering is the fallback.
    @discardableResult
    private static func screencapture(_ window: NSWindow, to url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }
}
#endif
