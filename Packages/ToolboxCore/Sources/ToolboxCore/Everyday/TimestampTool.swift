import Foundation

public enum TimestampTool {
    public enum Unit: String, Sendable, CaseIterable {
        case seconds, milliseconds, microseconds, nanoseconds
    }

    public struct Conversion: Equatable, Sendable {
        public let date: Date
        /// The unit the input was interpreted in (nil for ISO 8601 input).
        public let detectedUnit: Unit?

        public var seconds: Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
        public var milliseconds: Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
        public var iso8601UTC: String { TimestampTool.iso8601(date, timeZone: TimeZone(identifier: "UTC")!) }
        public func iso8601(in timeZone: TimeZone) -> String { TimestampTool.iso8601(date, timeZone: timeZone) }
        public func relative(to now: Date = Date()) -> String { TimestampTool.relativeDescription(of: date, now: now) }
    }

    /// Parses a Unix timestamp (unit guessed from its size) or an ISO 8601 date.
    public static func parse(_ input: String) -> Conversion? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let value = Double(text), text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) {
            let integerDigits = text.split(separator: ".").first.map { $0.filter(\.isNumber).count } ?? 0
            let unit: Unit
            switch integerDigits {
            case ...11: unit = .seconds
            case 12...14: unit = .milliseconds
            case 15...17: unit = .microseconds
            default: unit = .nanoseconds
            }
            let divisor: Double = [.seconds: 1, .milliseconds: 1e3, .microseconds: 1e6, .nanoseconds: 1e9][unit]!
            return Conversion(date: Date(timeIntervalSince1970: value / divisor), detectedUnit: unit)
        }

        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
            [.withFullDate],
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text) {
                return Conversion(date: date, detectedUnit: nil)
            }
        }
        return nil
    }

    static func iso8601(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func relativeDescription(of date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        let magnitude = abs(delta)
        if magnitude < 1 { return "now" }
        let units: [(Double, String)] = [(31_536_000, "year"), (2_592_000, "month"), (86_400, "day"), (3_600, "hour"), (60, "minute"), (1, "second")]
        let (size, name) = units.first(where: { magnitude >= $0.0 })!
        let count = Int(magnitude / size)
        let phrase = "\(count) \(name)\(count == 1 ? "" : "s")"
        return delta < 0 ? "\(phrase) ago" : "in \(phrase)"
    }
}
