import SwiftUI

/// Compact quality chip (FLAC / MP3 / Cached) — TIDAL-style, not Apple pill clusters.
struct QualityBadge: View {
    enum Kind: Equatable {
        case lossless
        case compressed
        case cached
        case custom(String)

        var label: String {
            switch self {
            case .lossless: return "LOSSLESS"
            case .compressed: return "MP3"
            case .cached: return "CACHED"
            case .custom(let s): return s.uppercased()
            }
        }

        var tint: Color {
            switch self {
            case .lossless: return Color(red: 0.92, green: 0.78, blue: 0.35)
            case .compressed: return DromeTheme.muted
            case .cached: return DromeTheme.accent
            case .custom: return DromeTheme.accent
            }
        }
    }

    let kind: Kind
    var compact: Bool = false

    var body: some View {
        Text(kind.label)
            .font(.system(size: compact ? 8 : 9, weight: .bold, design: .default))
            .tracking(0.6)
            .foregroundStyle(kind.tint)
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 2 : 3)
            .background(kind.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel(kind.label)
    }

    /// Map a Now Playing / song quality string into a badge kind.
    static func kind(from badge: String?) -> Kind? {
        guard let badge, !badge.isEmpty else { return nil }
        let upper = badge.uppercased()
        if upper.contains("FLAC") || upper.contains("ALAC") || upper.contains("WAV")
            || upper.contains("AIFF") || upper.contains("LOSSLESS") {
            return .lossless
        }
        if upper.contains("CACH") || upper.contains("OFFLINE") {
            return .cached
        }
        if upper.contains("MP3") || upper.contains("AAC") || upper.contains("OPUS")
            || upper.contains("OGG") || upper.contains("KBPS") {
            return .compressed
        }
        let short = badge.split(separator: "·").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return .custom(short ?? badge)
    }
}
