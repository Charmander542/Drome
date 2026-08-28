import Foundation
#if os(iOS)
import UIKit
#endif

/// Lightweight on-disk breadcrumb log for post-crash debugging.
/// View or share from Settings → Diagnostics after a crash.
enum DromeDiagnostics {
    enum Category: String {
        case app = "app"
        case player = "player"
        case network = "net"
        case session = "session"
    }

    private static let queue = DispatchQueue(label: "com.drome.diagnostics", qos: .utility)
    private static let maxMemoryLines = 400
    private static let maxFileBytes = 512 * 1024
    private static var memoryLines: [String] = []
    private static var installed = false

    static var logFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Drome", isDirectory: true)
            .appendingPathComponent("diagnostics.log")
    }

    static var recentText: String {
        queue.sync { memoryLines.joined(separator: "\n") }
    }

    static func install() {
        queue.async {
            guard !installed else { return }
            installed = true
            ensureDirectory()
            installExceptionHandler()
            logLaunchHeader()
        }
    }

    static func log(_ message: String, category: Category = .app) {
        let line = formatLine(message, category: category)
        queue.async { append(line) }
    }

    static func logPlayer(_ message: String) {
        log(message, category: .player)
    }

    static func logNetwork(_ message: String) {
        log(message, category: .network)
    }

    static func flush() {
        queue.sync { }
    }

    static func clearLog() {
        queue.async {
            memoryLines.removeAll()
            try? FileManager.default.removeItem(at: logFileURL)
            append(formatLine("log cleared", category: .app))
        }
    }

    @MainActor
    static func snapshotPlayer(_ player: PlayerEngine, note: String) {
        log("snapshot(\(note)) \(player.diagnosticStateLine())", category: .player)
    }

    // MARK: - Private

    private static func formatLine(_ message: String, category: Category) -> String {
        let ts = ISO8601DateFormatter.dromeDiagnostics.string(from: Date())
        return "\(ts) [\(category.rawValue)] \(message)"
    }

    private static func ensureDirectory() {
        let dir = logFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func append(_ line: String) {
        memoryLines.append(line)
        if memoryLines.count > maxMemoryLines {
            memoryLines.removeFirst(memoryLines.count - maxMemoryLines)
        }
        persist(line)
    }

    private static func persist(_ line: String) {
        ensureDirectory()
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let url = logFileURL
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
            rotateIfNeeded(url: url)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func rotateIfNeeded(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > maxFileBytes,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let keep = String(text.suffix(maxFileBytes / 2))
        try? keep.write(to: url, atomically: true, encoding: .utf8)
        memoryLines = keep.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private static func logLaunchHeader() {
        #if os(iOS)
        let device = UIDevice.current
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        append(formatLine(
            "launch \(device.model) iOS \(device.systemVersion) drome \(version) (\(build))",
            category: .app))
        #else
        append(formatLine("launch", category: .app))
        #endif
    }

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler(dromeUncaughtExceptionHandler)
    }

    /// Last-resort sync write (uncaught Obj-C exceptions only).
    fileprivate static func recordSynchronously(_ message: String, category: Category) {
        queue.sync { append(formatLine(message, category: category)) }
    }
}

/// Top-level handler required — Swift closures cannot form C function pointers.
private func dromeUncaughtExceptionHandler(_ exception: NSException) {
    let msg = "uncaught \(exception.name.rawValue): \(exception.reason ?? "unknown")"
    DromeDiagnostics.recordSynchronously(msg, category: .app)
}

private extension ISO8601DateFormatter {
    static let dromeDiagnostics: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
