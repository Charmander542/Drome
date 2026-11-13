import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// Lightweight on-disk breadcrumb log for post-crash / playback debugging.
/// Settings → Diagnostics → **Copy report for Cursor** builds a paste-ready
/// package with environment + live player state + recent events.
enum DromeDiagnostics {
    enum Category: String {
        case app = "app"
        case player = "player"
        case podcast = "podcast"
        case network = "net"
        case session = "session"
        case incident = "incident"
    }

    private static let queue = DispatchQueue(label: "com.drome.diagnostics", qos: .utility)
    private static let maxMemoryLines = 800
    private static let maxFileBytes = 1024 * 1024
    private static var memoryLines: [String] = []
    private static var installed = false
    /// Ring of recent incident markers so the copy package can highlight them.
    private static var recentIncidents: [String] = []
    private static let maxIncidents = 12

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

    static func logPodcast(_ message: String) {
        log(message, category: .podcast)
    }

    /// Mark a notable playback failure and capture a one-line snapshot.
    /// Call from stall / fail / circuit-break paths so the copy package
    /// surfaces the important moments first.
    @MainActor
    static func logIncident(_ title: String, player: PlayerEngine? = nil) {
        let detail = player.map { " \($0.diagnosticStateLine())" } ?? ""
        let message = "INCIDENT \(title)\(detail)"
        log(message, category: .incident)
        queue.async {
            recentIncidents.append(formatLine(message, category: .incident))
            if recentIncidents.count > maxIncidents {
                recentIncidents.removeFirst(recentIncidents.count - maxIncidents)
            }
        }
        if let player {
            snapshotPlayer(player, note: title)
        }
    }

    static func flush() {
        queue.sync { }
    }

    static func clearLog() {
        queue.async {
            memoryLines.removeAll()
            recentIncidents.removeAll()
            try? FileManager.default.removeItem(at: logFileURL)
            append(formatLine("log cleared", category: .app))
        }
    }

    @MainActor
    static func snapshotPlayer(_ player: PlayerEngine, note: String) {
        log("snapshot(\(note)) \(player.diagnosticStateLine())", category: .player)
        for line in player.diagnosticReportLines(note: note) {
            log(line, category: .player)
        }
    }

    /// Paste-ready package: environment, live player dump, incidents, tail of log.
    /// Designed so Charlie can drop it into chat and we have enough to fix.
    @MainActor
    static func copyReadyReport(player: PlayerEngine?) -> String {
        flush()
        if let player {
            snapshotPlayer(player, note: "copy-report")
            flush()
        }

        var sections: [String] = []
        sections.append("=== DROME PLAYBACK REPORT ===")
        sections.append("Generated: \(ISO8601DateFormatter.dromeDiagnostics.string(from: Date()))")
        sections.append("Paste this whole block into Cursor when something sounds wrong.")
        sections.append("")

        sections.append("--- Environment ---")
        sections.append(contentsOf: environmentLines())
        sections.append("")

        if let player {
            sections.append("--- Live player ---")
            sections.append(contentsOf: player.diagnosticReportLines(note: "live"))
            sections.append("")
        }

        let incidents = queue.sync { recentIncidents }
        if !incidents.isEmpty {
            sections.append("--- Recent incidents ---")
            sections.append(contentsOf: incidents)
            sections.append("")
        }

        sections.append("--- Event log (newest last) ---")
        let log = recentText
        if log.isEmpty {
            sections.append("(empty)")
        } else {
            // Keep the package under ~paste limits while retaining the useful tail.
            let lines = log.components(separatedBy: "\n")
            let tail = lines.suffix(350)
            if lines.count > tail.count {
                sections.append("… (\(lines.count - tail.count) older lines omitted)")
            }
            sections.append(contentsOf: tail)
        }
        sections.append("")
        sections.append("=== END DROME REPORT ===")
        return sections.joined(separator: "\n")
    }

    /// Redact secrets from stream / auth URLs before logging.
    static func redactedURL(_ url: URL?) -> String {
        guard let url else { return "nil" }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        if let items = comps.queryItems, !items.isEmpty {
            let secretKeys: Set<String> = [
                "u", "p", "s", "t", "c", "f", "pass", "password", "token", "salt", "auth", "apiKey",
            ]
            comps.queryItems = items.map { item in
                let key = item.name.lowercased()
                if secretKeys.contains(key) || key.contains("pass") || key.contains("token")
                    || key.contains("salt") || key.contains("auth") {
                    return URLQueryItem(name: item.name, value: "…")
                }
                return item
            }
        }
        let host = comps.host ?? "?"
        let path = comps.path
        let query = comps.percentEncodedQuery.map { "?\($0)" } ?? ""
        let scheme = comps.scheme ?? "https"
        return "\(scheme)://\(host)\(path)\(query)"
    }

    // MARK: - Private

    @MainActor
    private static func environmentLines() -> [String] {
        var lines: [String] = []
        #if os(iOS)
        let device = UIDevice.current
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("device=\(device.model) iOS=\(device.systemVersion) drome=\(version)(\(build))")
        #else
        lines.append("platform=tvOS/other")
        #endif
        #if !os(tvOS)
        lines.append("network online=\(ConnectivityMonitor.lastIsOnline) cellular=\(ConnectivityMonitor.lastIsCellular) expensive=\(ConnectivityMonitor.lastIsExpensive) path=\(ConnectivityMonitor.lastInterfaceSummary)")
        #endif
        let session = AVAudioSession.sharedInstance()
        let outs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        lines.append("audio category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=[\(outs)]")
        lines.append("audioFocus=\(AudioFocus.shared.ownerLabel) lastFocus=\(AudioFocus.shared.lastOwnerLabel)")
        lines.append("prefs compressCellular=\(PlaybackPreferences.compressOnCellular) resilientRemote=\(PlaybackPreferences.resilientRemoteStreaming) bitRate=\(PlaybackPreferences.cellularMaxBitRate)")
        return lines
    }

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

extension AudioFocus {
    fileprivate var ownerLabel: String {
        switch owner {
        case .none: return "none"
        case .music: return "music"
        case .podcast: return "podcast"
        }
    }

    fileprivate var lastOwnerLabel: String {
        switch lastOwner {
        case .none: return "none"
        case .music: return "music"
        case .podcast: return "podcast"
        }
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
