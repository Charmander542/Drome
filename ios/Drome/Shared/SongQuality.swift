import Foundation

extension Song {
    /// Human-readable quality badge, e.g. `FLAC · 24-bit/96 kHz` or `320 kbps`.
    var qualityBadge: String? {
        let format = formatLabel
        var parts: [String] = []
        if let format { parts.append(format) }

        if let bitDepth, bitDepth > 0, let samplingRate, samplingRate > 0 {
            let khz: String
            if samplingRate >= 1000 {
                let value = Double(samplingRate) / 1000.0
                if value == value.rounded() {
                    khz = String(format: "%.0f", value)
                } else {
                    khz = String(format: "%.1f", value)
                }
            } else {
                khz = "\(samplingRate)"
            }
            parts.append("\(bitDepth)-bit/\(khz) kHz")
        } else if let bitRate, bitRate > 0 {
            parts.append("\(bitRate) kbps")
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Remote hi-res / lossless should own the network pipe by itself.
    var needsSoloStream: Bool {
        if let bitDepth, bitDepth >= 24 { return true }
        if let samplingRate, samplingRate > 48_000 { return true }
        // High bitrates are almost always lossless even when tags are sparse.
        if let bitRate, bitRate >= 800 { return true }
        let suffix = (suffix ?? "").lowercased()
        if ["flac", "wav", "aiff", "aif", "dsf", "dff", "alac", "ape", "wv"].contains(suffix) {
            return true
        }
        let type = (contentType ?? "").lowercased()
        return type.contains("flac")
            || type.contains("wav")
            || type.contains("aiff")
            || type.contains("alac")
    }

    private var formatLabel: String? {
        if let suffix, !suffix.isEmpty {
            return suffix.uppercased()
        }
        if let contentType {
            let lower = contentType.lowercased()
            if lower.contains("flac") { return "FLAC" }
            if lower.contains("mpeg") || lower.contains("mp3") { return "MP3" }
            if lower.contains("mp4") || lower.contains("m4a") || lower.contains("aac") { return "AAC" }
            if lower.contains("ogg") || lower.contains("vorbis") { return "OGG" }
            if lower.contains("opus") { return "OPUS" }
            if lower.contains("wav") { return "WAV" }
            if lower.contains("aiff") { return "AIFF" }
        }
        return nil
    }
}
