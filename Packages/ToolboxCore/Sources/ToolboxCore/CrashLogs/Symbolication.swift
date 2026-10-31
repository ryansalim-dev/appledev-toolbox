import Foundation

/// Pure helpers for symbolicating a crash report with `atos` and finding dSYMs.
/// Running the commands is the app's job (see App/Sources/Platform); everything here is testable.
public enum Symbolication {
    /// One `atos` invocation: all unsymbolicated addresses that belong to one binary image.
    public struct Request: Equatable, Sendable {
        public var image: CrashReport.BinaryImage
        public var addresses: [UInt64]
    }

    /// Groups the unsymbolicated frames (all threads + last exception backtrace) by image.
    public static func requests(for report: CrashReport) -> [Request] {
        var byImage: [Int: [UInt64]] = [:]
        let allFrames = report.threads.flatMap(\.frames) + report.lastExceptionBacktrace
        for frame in allFrames where !frame.isSymbolicated {
            guard let index = frame.imageIndex, let address = frame.address(in: report.images) else { continue }
            if !(byImage[index]?.contains(address) ?? false) {
                byImage[index, default: []].append(address)
            }
        }
        return byImage.keys.sorted().compactMap { index in
            guard report.images.indices.contains(index), report.images[index].uuid != nil else { return nil }
            return Request(image: report.images[index], addresses: byImage[index]!)
        }
    }

    /// Arguments for `/usr/bin/xcrun`, e.g. `atos -arch arm64 -o <binary> -l 0x100000000 0x100001234 …`.
    public static func atosArguments(for request: Request, binaryPath: String) -> [String] {
        ["atos", "-arch", request.image.arch ?? "arm64", "-o", binaryPath,
         "-l", "0x" + String(request.image.loadAddress, radix: 16)]
            + request.addresses.map { "0x" + String($0, radix: 16) }
    }

    /// Parses `atos` output: one line per address, in the order given. Lines atos couldn't
    /// resolve echo the address back (`0x…`) and are skipped.
    ///
    /// Typical lines: `MyView.body.getter (in MyApp) (MyView.swift:42)` or `foo (in MyApp) + 40`.
    public static func parseAtosOutput(_ output: String, addresses: [UInt64]) -> [UInt64: ResolvedSymbol] {
        var result: [UInt64: ResolvedSymbol] = [:]
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for (address, raw) in zip(addresses, lines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("0x") else { continue }
            result[address] = parseAtosLine(line)
        }
        return result
    }

    static func parseAtosLine(_ line: String) -> ResolvedSymbol {
        var symbol = line
        var file: String?
        var lineNumber: Int?
        // Trailing "(File.swift:42)"
        if line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) {
            let inner = line[open.upperBound..<line.index(before: line.endIndex)]
            if let colon = inner.lastIndex(of: ":"), let n = Int(inner[inner.index(after: colon)...]) {
                file = String(inner[..<colon])
                lineNumber = n
                symbol = String(line[..<open.lowerBound])
            }
        }
        // Drop " (in MyApp)" and " + 123" decorations from the symbol.
        if let inRange = symbol.range(of: " (in ") { symbol = String(symbol[..<inRange.lowerBound]) }
        return ResolvedSymbol(symbol: symbol, sourceFile: file, sourceLine: lineNumber)
    }

    /// Spotlight query that finds a dSYM by UUID: `mdfind "com_apple_xcode_dsym_uuids == <UUID>"`.
    public static func spotlightQuery(forUUID uuid: String) -> String {
        "com_apple_xcode_dsym_uuids == \(CrashReport.normalizeUUID(uuid))"
    }

    /// Parses `dwarfdump --uuid` output into (UUID, arch, path) entries.
    /// Line format: `UUID: 1A2B3C4D-… (arm64) /path/MyApp.app.dSYM/Contents/Resources/DWARF/MyApp`
    public static func parseDwarfdumpUUIDs(_ output: String) -> [(uuid: String, arch: String, path: String)] {
        output.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("UUID: ") else { return nil }
            let rest = line.dropFirst(6)
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let uuid = String(rest[..<space])
            let afterUUID = rest[space...].trimmingCharacters(in: .whitespaces)
            guard afterUUID.hasPrefix("("), let close = afterUUID.firstIndex(of: ")") else { return nil }
            let arch = String(afterUUID[afterUUID.index(after: afterUUID.startIndex)..<close])
            let path = afterUUID[afterUUID.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return (CrashReport.normalizeUUID(uuid), arch, path)
        }
    }

    /// The DWARF binary inside a dSYM bundle: `X.dSYM/Contents/Resources/DWARF/<name>`.
    public static func dwarfBinaryDirectory(inDSYM dsym: URL) -> URL {
        dsym.appendingPathComponent("Contents/Resources/DWARF", isDirectory: true)
    }
}
