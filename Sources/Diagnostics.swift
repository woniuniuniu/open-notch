import AppKit
import Foundation

@MainActor
final class Diagnostics {
    static let shared = Diagnostics()

    private let maxLines = 500
    private var lines: [String] = []
    private let fileURL: URL
    private let persistenceQueue = DispatchQueue(label: "com.openbartender.OpenNotch.Diagnostics", qos: .utility)
    private var pendingWrite: DispatchWorkItem?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Open Notch", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("debug.log")
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = existing.split(separator: "\n").suffix(maxLines).map(String.init)
        }
    }

    func append(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: .now)
        lines.append("\(stamp) \(message)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        schedulePersistence()
    }

    func exportReport(summary: String) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let url = desktop.appendingPathComponent("Open Notch Debug \(formatter.string(from: .now)).txt")
        let report = "Open Notch Debug Report\n\n\(summary)\n\nRecent log\n----------\n\(lines.joined(separator: "\n"))\n"
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            append("Exported debug report to \(url.path)")
            return url
        } catch {
            append("Debug export failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func schedulePersistence() {
        pendingWrite?.cancel()
        let content = lines.joined(separator: "\n").appending("\n")
        let url = fileURL
        let work = DispatchWorkItem {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
        pendingWrite = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
