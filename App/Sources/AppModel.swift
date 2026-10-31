import AppKit
import Observation
import ToolboxCore
import UniformTypeIdentifiers

/// App-wide state: the selected tool, and input routed to tools by paste / drop / open.
@MainActor
@Observable
final class AppModel {
    var selection: ToolID? = .json

    // Input buffers, so routed content lands in the right tool and survives switching tools.
    var jsonInput = ""
    var codableInput = ""
    var jwtInput = ""
    var base64Input = ""
    var timestampInput = ""
    var crashLogText = ""
    var crashLogURL: URL?
    var openedProfile: ProvisioningProfile?
    var plistItem: PlistItem?
    var appBundleURL: URL?
    var linksDomain = ""

    struct PlistItem: Equatable {
        let id = UUID()
        let name: String
        let data: Data
    }

    /// A short message shown when input couldn't be routed.
    var notice: String?

    // MARK: - Routing

    func route(text: String) {
        notice = nil
        switch InputDetector.detect(text: text) {
        case .jwt: jwtInput = text; selection = .jwt
        case .json: jsonInput = text; selection = .json
        case .crashLog: crashLogText = text; crashLogURL = nil; selection = .crashLogs
        case .unixTimestamp: timestampInput = text; selection = .timestamp
        case .base64: base64Input = text; selection = .base64
        case .propertyList:
            plistItem = PlistItem(name: "Pasted property list", data: Data(text.utf8))
            appBundleURL = nil
            selection = .plist
        case .provisioningProfile: selection = .profiles
        case .unknown: notice = "Couldn't tell what that is. Pick a tool from the sidebar."
        }
    }

    func route(fileURL url: URL) {
        notice = nil
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // .app bundles are folders and .ipa files are zips: open them in the Plist tool.
        if PlistLoader.isAppBundle(url) {
            appBundleURL = url
            plistItem = nil
            selection = .plist
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            notice = "Couldn't read \(url.lastPathComponent)."
            return
        }
        switch InputDetector.detect(fileExtension: url.pathExtension, data: data) {
        case .provisioningProfile:
            do {
                openedProfile = try ProvisioningProfile.parse(data, fileURL: url)
                selection = .profiles
            } catch {
                notice = String(describing: error)
            }
        case .crashLog:
            crashLogText = String(decoding: data, as: UTF8.self)
            crashLogURL = url
            selection = .crashLogs
        case .propertyList:
            plistItem = PlistItem(name: url.lastPathComponent, data: data)
            appBundleURL = nil
            selection = .plist
        default:
            if let text = String(data: data, encoding: .utf8) {
                route(text: text)
            } else {
                notice = "\(url.lastPathComponent) isn't a file type the toolbox understands yet."
            }
        }
    }

    func pasteAndDetect() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first {
            route(fileURL: first)
        } else if let text = pasteboard.string(forType: .string) {
            route(text: text)
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            route(fileURL: url)
        }
    }
}
