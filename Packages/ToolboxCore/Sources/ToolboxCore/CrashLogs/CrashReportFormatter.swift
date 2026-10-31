import Foundation

/// A symbol resolved by `atos`, keyed by absolute address.
public struct ResolvedSymbol: Equatable, Sendable {
    public var symbol: String
    public var sourceFile: String?
    public var sourceLine: Int?

    public init(symbol: String, sourceFile: String? = nil, sourceLine: Int? = nil) {
        self.symbol = symbol
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
    }
}

/// Renders a `CrashReport` as the classic text crash log developers know.
public enum CrashReportFormatter {
    public static func text(for report: CrashReport, resolved: [UInt64: ResolvedSymbol] = [:]) -> String {
        var out: [String] = []

        func field(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            out.append((label + ":").padding(toLength: 20, withPad: " ", startingAt: 0) + value)
        }

        field("Incident Identifier", report.incidentID)
        field("Hardware Model", report.hardwareModel)
        field("Process", [report.processName, report.pid.map { "[\($0)]" }].compactMap { $0 }.joined(separator: " "))
        field("Path", report.processPath)
        field("Identifier", report.bundleID)
        field("Version", report.appVersion.map { v in report.buildVersion.map { "\(v) (\($0))" } ?? v })
        field("Code Type", report.cpuType)
        field("Parent Process", report.parentProcess)
        out.append("")
        field("Date/Time", report.captureTime)
        field("Launch Time", report.launchTime)
        field("OS Version", report.osVersion)
        out.append("")

        if let e = report.exception {
            field("Exception Type", [e.type, e.signal.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
            field("Exception Codes", e.codes)
            field("Exception Subtype", e.subtype)
            field("Exception Message", e.message)
        }
        if let t = report.termination {
            let reason = [t.namespace, t.code.map(String.init), t.indicator].compactMap { $0 }.joined(separator: " ")
            field("Termination Reason", reason)
            field("Terminating Process", t.byProcess)
            for r in t.reasons { out.append("    " + r) }
        }
        if let crashed = report.crashedThread {
            field("Triggered by Thread", String(crashed.index))
        }

        if !report.applicationMessages.isEmpty {
            out.append("")
            out.append("Application Specific Information:")
            out.append(contentsOf: report.applicationMessages)
        }

        if !report.lastExceptionBacktrace.isEmpty {
            out.append("")
            out.append("Last Exception Backtrace:")
            out.append(contentsOf: frameLines(report.lastExceptionBacktrace, report: report, resolved: resolved))
        }

        for thread in report.threads {
            out.append("")
            var title = "Thread \(thread.index)"
            if thread.triggered { title += " Crashed" }
            title += ":"
            if let name = thread.name { title += ": \(name)" }
            if let queue = thread.queue { title += ":  Dispatch queue: \(queue)" }
            out.append(title)
            out.append(contentsOf: frameLines(thread.frames, report: report, resolved: resolved))
        }

        if !report.images.isEmpty {
            out.append("")
            out.append("Binary Images:")
            for image in report.images {
                let end = image.size.map { image.loadAddress &+ $0 &- 1 }
                let range = "0x" + String(image.loadAddress, radix: 16) + " - " + (end.map { "0x" + String($0, radix: 16) } ?? "?")
                let name = image.name ?? "???"
                let uuid = image.uuid.map { "<\($0.lowercased().filter { $0 != "-" })>" } ?? ""
                out.append([range, name, image.arch ?? "", uuid, image.path ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
            }
        }

        return out.joined(separator: "\n") + "\n"
    }

    static func frameLines(_ frames: [CrashReport.Frame], report: CrashReport, resolved: [UInt64: ResolvedSymbol]) -> [String] {
        frames.enumerated().map { number, frame in
            let image = frame.imageIndex.flatMap { report.images.indices.contains($0) ? report.images[$0] : nil }
            let imageName = (image?.name ?? "???").padding(toLength: 30, withPad: " ", startingAt: 0)
            let address = frame.address(in: report.images)
            let addressText = address.map(hex16) ?? "0x????????????????"

            var description: String
            if let address, let r = resolved[address] {
                description = r.symbol
                if let file = r.sourceFile { description += " (\(file)\(r.sourceLine.map { ":\($0)" } ?? ""))" }
            } else if let symbol = frame.symbol {
                description = symbol + (frame.symbolLocation.map { " + \($0)" } ?? "")
                if let file = frame.sourceFile {
                    description += " (\((file as NSString).lastPathComponent)\(frame.sourceLine.map { ":\($0)" } ?? ""))"
                }
            } else if let image, let offset = frame.imageOffset {
                description = "0x" + String(image.loadAddress, radix: 16) + " + \(offset)"
            } else {
                description = "???"
            }
            return String(number).padding(toLength: 4, withPad: " ", startingAt: 0) + imageName + "\t" + addressText + " " + description
        }
    }

    static func hex16(_ value: UInt64) -> String {
        let h = String(value, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, 16 - h.count)) + h
    }
}
