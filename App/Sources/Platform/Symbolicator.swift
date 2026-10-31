import Foundation
import ToolboxCore

/// Finds dSYMs (Spotlight + folders the user picked) and runs `atos` for each image with unsymbolicated frames.
struct Symbolicator {
    struct Outcome {
        var resolved: [UInt64: ResolvedSymbol] = [:]
        /// Images whose dSYM wasn't found.
        var missing: [String] = []
        var errors: [String] = []
    }

    var extraSearchFolders: [URL] = []

    func symbolicate(_ report: CrashReport) async -> Outcome {
        var outcome = Outcome()
        for request in Symbolication.requests(for: report) {
            let imageName = request.image.name ?? "unknown image"
            guard let uuid = request.image.normalizedUUID else { continue }
            guard let binary = await findDWARFBinary(uuid: uuid) else {
                outcome.missing.append("\(imageName) (\(uuid))")
                continue
            }
            do {
                let output = try await CommandRunner.xcrun(Symbolication.atosArguments(for: request, binaryPath: binary.path))
                outcome.resolved.merge(Symbolication.parseAtosOutput(output, addresses: request.addresses)) { a, _ in a }
            } catch {
                outcome.errors.append("\(imageName): \(error)")
            }
        }
        return outcome
    }

    /// Returns the DWARF binary inside a dSYM whose UUID matches.
    func findDWARFBinary(uuid: String) async -> URL? {
        var candidates: [URL] = []

        // 1. Spotlight indexes dSYM UUIDs (Xcode archives, DerivedData).
        if let output = try? await CommandRunner.run("/usr/bin/mdfind", [Symbolication.spotlightQuery(forUUID: uuid)]) {
            candidates += output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        }

        // 2. dSYM bundles in folders the user chose.
        for folder in extraSearchFolders {
            candidates += dSYMBundles(in: folder)
        }

        for dsym in candidates {
            let dwarfDirectory = Symbolication.dwarfBinaryDirectory(inDSYM: dsym)
            guard let binaries = try? FileManager.default.contentsOfDirectory(at: dwarfDirectory, includingPropertiesForKeys: nil) else { continue }
            for binary in binaries {
                guard let output = try? await CommandRunner.xcrun(["dwarfdump", "--uuid", binary.path]) else { continue }
                if Symbolication.parseDwarfdumpUUIDs(output).contains(where: { $0.uuid == uuid }) {
                    return binary
                }
            }
        }
        return nil
    }

    private func dSYMBundles(in folder: URL) -> [URL] {
        if folder.pathExtension == "dSYM" { return [folder] }
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var bundles: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "dSYM" {
            bundles.append(url)
        }
        return bundles
    }
}
