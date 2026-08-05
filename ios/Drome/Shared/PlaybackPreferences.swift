import Foundation

/// User-tunable playback preferences persisted in UserDefaults.
@MainActor
enum PlaybackPreferences {
    private static let skipLowRatedKey = "drome.skipLowRatedEverywhere"
    private static let recencyHoursKey = "drome.autoplayRecencyHours"

    static var skipLowRatedEverywhere: Bool {
        get { UserDefaults.standard.bool(forKey: skipLowRatedKey) }
        set { UserDefaults.standard.set(newValue, forKey: skipLowRatedKey) }
    }

    /// Hard exclusion window for Infinite Shuffle (hours). Default 72.
    static var autoplayRecencyHours: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: recencyHoursKey)
            return stored > 0 ? stored : 72
        }
        set { UserDefaults.standard.set(newValue, forKey: recencyHoursKey) }
    }
}

/// Formats multi-artist credits for display.
enum ArtistCredits {
    /// Prefer OpenSubsonic `artists[]` when present; otherwise parse common
    /// separators in the single `artist` string.
    static func display(for song: Song) -> String {
        if let artists = song.artists, !artists.isEmpty {
            return artists.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return split(song.artist ?? "").joined(separator: ", ")
    }

    static func display(albumArtist: String?, artists: [ArtistRef]?) -> String {
        if let artists, !artists.isEmpty {
            return artists.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return split(albumArtist ?? "").joined(separator: ", ")
    }

    static func split(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = #"\s*(?:,|;|/|\s+&(?:amp;)?\s+|\s+feat\.?\s+|\s+ft\.?\s+|\s+with\s+)\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return [trimmed]
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let parts = regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "\u{1F}")
            .split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [trimmed] : parts
    }
}
