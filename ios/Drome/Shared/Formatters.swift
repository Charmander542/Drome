import Foundation

enum Formatters {
    static func duration(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func playbackTime(_ time: TimeInterval) -> String {
        duration(seconds: max(0, Int(time.rounded())))
    }

    static func longDuration(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h) hr \(m) min" }
        return "\(m) min"
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension Array where Element == Song {
    /// Removes duplicate songs by id, keeping first occurrence.
    func uniquedByID() -> [Song] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}
