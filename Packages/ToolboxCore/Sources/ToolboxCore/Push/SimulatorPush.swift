import Foundation

/// Helpers for `xcrun simctl push`, which delivers a payload to a booted Simulator without APNs.
public enum SimulatorPush {
    public struct Device: Identifiable, Equatable, Sendable {
        public var id: String { udid }
        public let udid: String
        public let name: String
        /// e.g. "iOS 18.1", derived from the runtime identifier.
        public let runtime: String
        public let isBooted: Bool
    }

    /// Arguments for `xcrun simctl list devices booted --json`.
    public static let listArguments = ["simctl", "list", "devices", "booted", "--json"]

    /// Parses `simctl list devices --json` output.
    public static func parseDevices(_ json: String) -> [Device] {
        guard let root = try? JSONParser.parse(json), let runtimes = root["devices"]?.objectValue else { return [] }
        var devices: [Device] = []
        for runtime in runtimes {
            let runtimeName = humanRuntime(runtime.key)
            for device in runtime.value.arrayValue ?? [] {
                guard let udid = device["udid"]?.stringValue, let name = device["name"]?.stringValue else { continue }
                if device["isAvailable"]?.boolValue == false { continue }
                devices.append(Device(udid: udid, name: name, runtime: runtimeName, isBooted: device["state"]?.stringValue == "Booted"))
            }
        }
        return devices.sorted { ($0.name, $0.runtime) < ($1.name, $1.runtime) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-18-1` → `iOS 18.1`.
    static func humanRuntime(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return String(last) }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }

    /// Arguments for `xcrun simctl push <udid> <bundleID> <payloadPath>`.
    public static func pushArguments(deviceUDID: String, bundleID: String, payloadPath: String) -> [String] {
        ["simctl", "push", deviceUDID, bundleID, payloadPath]
    }
}
