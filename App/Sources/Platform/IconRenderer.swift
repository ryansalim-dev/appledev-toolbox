import CoreGraphics
import Foundation
import ImageIO
import ToolboxCore
import UniformTypeIdentifiers

enum IconRenderer {
    struct RenderError: Error, CustomStringConvertible {
        let description: String
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Resizes to a square of `pixels`. Opaque output is flattened onto `background`.
    static func render(_ image: CGImage, pixels: Int, opaque: Bool, background: CGColor) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        if opaque {
            context.setFillColor(background)
            context.fill(rect)
        }
        context.draw(image, in: rect)
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError(description: "Couldn't create \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError(description: "Couldn't write \(url.lastPathComponent).")
        }
    }

    /// Writes `AppIcon.appiconset` (PNGs + Contents.json) into `folder` and returns its URL.
    static func writeIconSet(
        plan: AppIconSet.Plan,
        sources: [AppIconSet.Variant: CGImage],
        background: CGColor,
        into folder: URL
    ) throws -> URL {
        let set = folder.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        for rendition in plan.renditions {
            guard let source = sources[rendition.variant] ?? sources[.standard] else { continue }
            guard let image = render(source, pixels: rendition.pixels, opaque: rendition.opaque, background: background) else {
                throw RenderError(description: "Couldn't render \(rendition.filename).")
            }
            try writePNG(image, to: set.appendingPathComponent(rendition.filename))
        }
        try plan.contentsJSON.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        return set
    }
}
