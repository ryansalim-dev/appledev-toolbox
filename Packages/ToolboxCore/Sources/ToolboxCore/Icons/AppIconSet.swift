import Foundation

/// Describes an `AppIcon.appiconset`: which PNGs to render and the matching `Contents.json`.
public enum AppIconSet {
    public enum Platform: String, CaseIterable, Sendable, Identifiable {
        case iOS = "iOS / iPadOS"
        case macOS = "macOS"
        case watchOS = "watchOS"
        public var id: String { rawValue }
    }

    /// iOS 18+ appearance variants.
    public enum Variant: String, CaseIterable, Sendable {
        case standard, dark, tinted

        var appearanceJSON: String? {
            switch self {
            case .standard: return nil
            case .dark: return #"[{"appearance":"luminosity","value":"dark"}]"#
            case .tinted: return #"[{"appearance":"luminosity","value":"tinted"}]"#
            }
        }
    }

    public struct Rendition: Equatable, Sendable {
        public var filename: String
        /// Output size in pixels (square).
        public var pixels: Int
        public var variant: Variant
        /// iOS icons must not have an alpha channel; macOS icons may.
        public var opaque: Bool
    }

    public struct Plan: Equatable, Sendable {
        public var renditions: [Rendition]
        public var contentsJSON: String
    }

    /// macOS still needs explicit sizes (points × scale).
    static let macSizes: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
    ]

    /// Builds the plan. iOS and watchOS use Xcode 14+'s single 1024 px size.
    public static func plan(platforms: Set<Platform>, variants: Set<Variant> = [.standard]) -> Plan {
        var renditions: [Rendition] = []
        var images: [String] = []

        if platforms.contains(.iOS) {
            for variant in Variant.allCases where variant == .standard || variants.contains(variant) {
                let name = variant == .standard ? "AppIcon-iOS-1024.png" : "AppIcon-iOS-1024-\(variant.rawValue).png"
                // Dark icons may be transparent so the system background shows through; light and tinted must be opaque.
                renditions.append(Rendition(filename: name, pixels: 1024, variant: variant, opaque: variant != .dark))
                var entry = #"{"filename":"\#(name)","idiom":"universal","platform":"ios","size":"1024x1024""#
                if let appearance = variant.appearanceJSON { entry += #","appearances":\#(appearance)"# }
                images.append(entry + "}")
            }
        }

        if platforms.contains(.macOS) {
            for (points, scale) in macSizes {
                let pixels = points * scale
                let name = "AppIcon-mac-\(points)x\(points)@\(scale)x.png"
                if !renditions.contains(where: { $0.filename == name }) {
                    renditions.append(Rendition(filename: name, pixels: pixels, variant: .standard, opaque: false))
                }
                images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(points)x\#(points)"}"#)
            }
        }

        if platforms.contains(.watchOS) {
            let name = "AppIcon-watch-1024.png"
            renditions.append(Rendition(filename: name, pixels: 1024, variant: .standard, opaque: true))
            images.append(#"{"filename":"\#(name)","idiom":"universal","platform":"watchos","size":"1024x1024"}"#)
        }

        let raw = #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
        let pretty = (try? JSONParser.parse(raw).formatted()) ?? raw
        return Plan(renditions: renditions, contentsJSON: pretty + "\n")
    }

    public struct SourceIssue: Equatable, Sendable {
        public enum Severity: Sendable { case error, warning }
        public var severity: Severity
        public var message: String
    }

    /// Checks a source image before rendering.
    public static func validateSource(width: Int, height: Int, hasAlpha: Bool, platforms: Set<Platform>, variant: Variant = .standard) -> [SourceIssue] {
        var issues: [SourceIssue] = []
        if width != height {
            issues.append(.init(severity: .error, message: "The image is \(width)×\(height); app icons must be square."))
        }
        if min(width, height) < 1024 {
            issues.append(.init(severity: .error, message: "The image is \(min(width, height)) px; use at least 1024×1024 so large sizes stay sharp."))
        }
        if hasAlpha, variant != .dark, platforms.contains(.iOS) || platforms.contains(.watchOS) {
            issues.append(.init(severity: .warning, message: "The image has transparency. iOS and watchOS icons must be opaque (App Store Connect rejects alpha). It will be flattened onto the background color."))
        }
        return issues
    }
}
