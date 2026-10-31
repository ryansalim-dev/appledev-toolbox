import Foundation

/// Everything needed to send one push through Apple Push Notification service.
public struct APNsRequest: Equatable, Sendable {
    public enum Environment: String, Sendable, CaseIterable {
        case sandbox = "Sandbox"
        case production = "Production"

        public var host: String {
            switch self {
            case .sandbox: return "api.sandbox.push.apple.com"
            case .production: return "api.push.apple.com"
            }
        }
    }

    /// Values for the `apns-push-type` header.
    public enum PushType: String, Sendable, CaseIterable {
        case alert, background, liveactivity, voip, complication, fileprovider, location, pushtotalk, widgets, controls

        /// Suffix APNs requires on the topic for this push type.
        public var topicSuffix: String? {
            switch self {
            case .liveactivity: return ".push-type.liveactivity"
            case .voip: return ".voip"
            case .complication: return ".complication"
            case .fileprovider: return ".pushkit.fileprovider"
            case .location: return ".location-query"
            case .pushtotalk: return ".voip-ptt"
            case .widgets: return ".push-type.widgets"
            case .controls: return ".push-type.controls"
            case .alert, .background: return nil
            }
        }

        /// The largest payload APNs accepts for this type, in bytes.
        public var maxPayloadBytes: Int { self == .voip ? 5_120 : 4_096 }
    }

    public enum Priority: Int, Sendable, CaseIterable {
        case immediate = 10
        case powerConsiderate = 5
        case low = 1
    }

    public var environment: Environment
    public var deviceToken: String
    /// Usually the app's bundle ID; `topic(for:)` adds the push-type suffix.
    public var bundleID: String
    public var pushType: PushType
    public var priority: Priority
    public var payload: String
    public var expiration: Date?
    public var collapseID: String?
    public var apnsID: UUID?

    public init(
        environment: Environment = .sandbox,
        deviceToken: String,
        bundleID: String,
        pushType: PushType = .alert,
        priority: Priority = .immediate,
        payload: String,
        expiration: Date? = nil,
        collapseID: String? = nil,
        apnsID: UUID? = nil
    ) {
        self.environment = environment
        self.deviceToken = deviceToken
        self.bundleID = bundleID
        self.pushType = pushType
        self.priority = priority
        self.payload = payload
        self.expiration = expiration
        self.collapseID = collapseID
        self.apnsID = apnsID
    }

    /// The device token with spaces, `<>` and dashes removed (people paste it in many shapes).
    public var normalizedDeviceToken: String {
        deviceToken.lowercased().filter { $0.isHexDigit }
    }

    /// The `apns-topic` value: bundle ID plus the suffix the push type requires.
    public var topic: String {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard let suffix = pushType.topicSuffix, !id.hasSuffix(suffix) else { return id }
        return id + suffix
    }

    public var url: URL {
        URL(string: "https://\(environment.host)/3/device/\(normalizedDeviceToken)")!
    }

    /// HTTP headers, excluding `authorization` (added by whoever holds the key).
    public var headers: [String: String] {
        var headers = [
            "apns-push-type": pushType.rawValue,
            "apns-topic": topic,
            "apns-priority": String(priority.rawValue),
            "content-type": "application/json",
        ]
        if let expiration { headers["apns-expiration"] = String(Int(expiration.timeIntervalSince1970)) }
        if let collapseID, !collapseID.isEmpty { headers["apns-collapse-id"] = collapseID }
        if let apnsID { headers["apns-id"] = apnsID.uuidString.lowercased() }
        return headers
    }

    public var body: Data { Data(payload.utf8) }
}

// MARK: - Validation

public extension APNsRequest {
    struct Issue: Equatable, Sendable {
        public enum Severity: Sendable { case error, warning }
        public var severity: Severity
        public var message: String

        public init(severity: Severity, message: String) {
            self.severity = severity
            self.message = message
        }
    }

    /// Problems APNs would reject, plus common mistakes that "succeed" but never show anything.
    func validate() -> [Issue] {
        var issues: [Issue] = []
        func error(_ m: String) { issues.append(Issue(severity: .error, message: m)) }
        func warning(_ m: String) { issues.append(Issue(severity: .warning, message: m)) }

        let token = normalizedDeviceToken
        if token.isEmpty {
            error("Enter a device token.")
        } else if token.count < 64 || token.count % 2 != 0 {
            error("Device tokens are at least 64 hex characters; this one has \(token.count).")
        }
        if bundleID.trimmingCharacters(in: .whitespaces).isEmpty { error("Enter the app's bundle ID (the APNs topic).") }

        let size = body.count
        if size > pushType.maxPayloadBytes {
            error("Payload is \(size) bytes; the limit for \(pushType.rawValue) pushes is \(pushType.maxPayloadBytes).")
        }

        guard let json = try? JSONParser.parse(payload) else {
            error("The payload isn't valid JSON.")
            return issues
        }
        guard let aps = json["aps"] else {
            if pushType != .voip, pushType != .fileprovider, pushType != .location {
                error("The payload needs an \"aps\" dictionary.")
            }
            return issues
        }

        switch pushType {
        case .background:
            if aps["content-available"]?.intValue != 1 {
                error("Background pushes need \"content-available\": 1 in aps.")
            }
            if aps["alert"] != nil || aps["sound"] != nil || aps["badge"] != nil {
                warning("Background pushes shouldn't include alert, sound or badge; use push type \"alert\" for visible notifications.")
            }
            if priority == .immediate {
                warning("Apple requires priority 5 for background pushes; priority 10 may be rejected or throttled.")
            }
        case .alert:
            if aps["alert"] == nil, aps["badge"] == nil, aps["sound"] == nil {
                warning("An alert push with no alert, badge or sound won't show anything.")
            }
            if aps["mutable-content"]?.intValue == 1, aps["alert"] == nil {
                warning("mutable-content only runs your Notification Service Extension when the push has an alert.")
            }
        case .liveactivity:
            if aps["event"] == nil { error("Live Activity pushes need \"event\" (start, update or end) in aps.") }
            if aps["timestamp"] == nil { error("Live Activity pushes need a \"timestamp\" in aps.") }
            if aps["event"]?.stringValue != "end", aps["content-state"] == nil {
                error("Live Activity start/update pushes need \"content-state\" in aps.")
            }
        default:
            break
        }
        return issues
    }
}

// MARK: - Response

/// What APNs answered, with a plain-English explanation of the failure reasons.
public struct APNsResponse: Equatable, Sendable {
    public var statusCode: Int
    public var apnsID: String?
    /// Sandbox only: the ID to look up in the Push Notifications Console delivery log.
    public var apnsUniqueID: String?
    public var reason: String?
    /// For 410 Unregistered: when the token stopped being valid.
    public var invalidSince: Date?

    public var isSuccess: Bool { statusCode == 200 }

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        apnsID = lower["apns-id"]
        apnsUniqueID = lower["apns-unique-id"]
        if !body.isEmpty, let json = try? JSONParser.parse(body) {
            reason = json["reason"]?.stringValue
            // APNs reports the timestamp in milliseconds.
            if let ms = json["timestamp"]?.doubleValue { invalidSince = Date(timeIntervalSince1970: ms / 1000) }
        }
    }

    public var explanation: String {
        if isSuccess { return "Accepted by APNs. Delivery to the device isn't guaranteed (Focus, Low Power, or the app's settings can still hide it)." }
        guard let reason else { return "APNs returned HTTP \(statusCode)." }
        return APNsResponse.explanations[reason] ?? "APNs rejected the push: \(reason)."
    }

    static let explanations: [String: String] = [
        "BadDeviceToken": "The device token is invalid, or it belongs to the other environment (a Debug build's token only works with Sandbox; TestFlight and App Store builds use Production).",
        "DeviceTokenNotForTopic": "The token belongs to a different app than the bundle ID you entered.",
        "TopicDisallowed": "Your key or certificate isn't allowed to send to this topic. Check the bundle ID and push type suffix.",
        "BadTopic": "The topic (bundle ID) is invalid.",
        "MissingTopic": "The topic (bundle ID) is missing.",
        "InvalidPushType": "The apns-push-type value isn't valid.",
        "BadCollapseId": "The collapse ID is longer than 64 bytes.",
        "BadPriority": "That priority isn't allowed for this push type.",
        "BadExpirationDate": "The expiration date is invalid.",
        "BadMessageId": "The apns-id isn't a valid UUID.",
        "PayloadEmpty": "The payload is empty.",
        "PayloadTooLarge": "The payload is over the size limit (4 KB, or 5 KB for VoIP).",
        "ExpiredProviderToken": "The signed token is older than an hour. Sending again creates a fresh one.",
        "InvalidProviderToken": "APNs couldn't verify the token. Check that the Key ID and Team ID match the .p8 key, and that the key has APNs enabled.",
        "MissingProviderToken": "No authentication token was sent.",
        "TooManyProviderTokenUpdates": "The token was refreshed too often. APNs allows one new token per 20 minutes per connection.",
        "Forbidden": "The key or certificate doesn't have permission for this action.",
        "BadCertificate": "The certificate is invalid.",
        "BadCertificateEnvironment": "The certificate is for the other environment (Sandbox vs Production).",
        "Unregistered": "The token is no longer active for this topic, usually because the app was deleted from the device.",
        "ExpiredToken": "The device token has expired.",
        "TooManyRequests": "Too many requests to this device token in a short time. Wait and try again.",
        "IdleTimeout": "The connection was idle too long.",
        "InternalServerError": "APNs had an internal error. Try again.",
        "ServiceUnavailable": "APNs is unavailable right now. Try again shortly.",
        "Shutdown": "The APNs server is shutting down. Try again.",
    ]
}

// MARK: - Payload templates

public enum APNsTemplates {
    public struct Template: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let pushType: APNsRequest.PushType
        public let priority: APNsRequest.Priority
        public let payload: String
    }

    public static func all(now: Date = Date()) -> [Template] {
        let timestamp = Int(now.timeIntervalSince1970)
        return [
            Template(name: "Alert", pushType: .alert, priority: .immediate, payload: """
            {
              "aps": {
                "alert": {
                  "title": "Hello",
                  "body": "Sent from AppleDev Toolbox"
                },
                "sound": "default"
              }
            }
            """),
            Template(name: "Alert with badge", pushType: .alert, priority: .immediate, payload: """
            {
              "aps": {
                "alert": "You have new messages",
                "badge": 3,
                "sound": "default"
              }
            }
            """),
            Template(name: "Rich (Notification Service Extension)", pushType: .alert, priority: .immediate, payload: """
            {
              "aps": {
                "alert": {
                  "title": "Photo",
                  "body": "Your image is ready"
                },
                "mutable-content": 1
              },
              "image-url": "https://example.com/image.jpg"
            }
            """),
            Template(name: "Silent background", pushType: .background, priority: .powerConsiderate, payload: """
            {
              "aps": {
                "content-available": 1
              }
            }
            """),
            Template(name: "Live Activity update", pushType: .liveactivity, priority: .immediate, payload: """
            {
              "aps": {
                "timestamp": \(timestamp),
                "event": "update",
                "content-state": {}
              }
            }
            """),
        ]
    }
}
