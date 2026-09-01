import AppKit
import Foundation

@MainActor
final class Diagnostics {
    static let shared = Diagnostics()

    private(set) var lines: [String] = []
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.woniuniuniu.OpenBar.diagnostics", qos: .utility)

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Open Bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("debug.log")
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = existing.split(separator: "\n").suffix(500).map(String.init)
        }
    }

    func append(_ message: String) {
        let entry = "\(ISO8601DateFormatter().string(from: .now)) \(message)"
        lines.append(entry)
        lines = Array(lines.suffix(500))
        let body = lines.joined(separator: "\n") + "\n"
        let url = fileURL
        queue.async { try? body.write(to: url, atomically: true, encoding: .utf8) }
    }

    func export(summary: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OPEN BAR Diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let body = "OPEN BAR / 若栏 Diagnostics\n\n\(summary)\n\n\(lines.joined(separator: "\n"))\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
