import Foundation

public enum Base64Tool {
    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case invalidCharacters
        case invalidLength
        public var description: String {
            switch self {
            case .invalidCharacters: return "The text contains characters that aren't Base64."
            case .invalidLength: return "The text isn't a valid Base64 length."
            }
        }
    }

    public static func encode(_ data: Data, urlSafe: Bool = false, padded: Bool = true) -> String {
        var s = data.base64EncodedString()
        if urlSafe {
            s = s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        if !padded {
            while s.hasSuffix("=") { s.removeLast() }
        }
        return s
    }

    public static func encode(_ text: String, urlSafe: Bool = false, padded: Bool = true) -> String {
        encode(Data(text.utf8), urlSafe: urlSafe, padded: padded)
    }

    /// Decodes standard or URL-safe Base64. Whitespace and missing padding are tolerated.
    public static func decode(_ text: String) throws -> Data {
        var s = text.filter { !$0.isWhitespace }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let body = Substring(s)
        let unpadded = body.hasSuffix("==") ? body.dropLast(2) : (body.hasSuffix("=") ? body.dropLast(1) : body[...])
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        guard unpadded.allSatisfy({ allowed.contains($0) }) else { throw DecodeError.invalidCharacters }
        if unpadded.count % 4 == 1 { throw DecodeError.invalidLength }
        var padded = String(unpadded)
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded) else { throw DecodeError.invalidLength }
        return data
    }

    /// The decoded bytes as UTF-8 text, or nil if they aren't valid UTF-8.
    public static func decodeToText(_ text: String) throws -> String? {
        String(data: try decode(text), encoding: .utf8)
    }

    /// A hex dump for binary results: `00000000  48 65 6c 6c 6f  |Hello|`.
    public static func hexDump(_ data: Data, bytesPerLine: Int = 16) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + bytesPerLine, bytes.count)]
            let hex = chunk.map { b -> String in
                let h = String(b, radix: 16)
                return h.count == 1 ? "0" + h : h
            }.joined(separator: " ")
            let ascii = String(chunk.map { (0x20...0x7E).contains($0) ? Character(Unicode.Scalar($0)) : "." })
            let off = String(offset, radix: 16)
            let paddedHex = hex.padding(toLength: bytesPerLine * 3 - 1, withPad: " ", startingAt: 0)
            lines.append(String(repeating: "0", count: max(0, 8 - off.count)) + off + "  " + paddedHex + "  |" + ascii + "|")
            offset += bytesPerLine
        }
        return lines.joined(separator: "\n")
    }
}
