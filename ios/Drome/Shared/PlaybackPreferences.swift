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

/// One credited artist under a song — optionally linked to a Navidrome artist id.
struct ArtistCredit: Hashable, Identifiable {
    var id: String { artistId ?? name }
    var name: String
    var artistId: String?
}

/// Formats multi-artist credits for display and navigation.
enum ArtistCredits {
    /// Prefer OpenSubsonic `artists[]` when present; otherwise parse common
    /// separators in the single `artist` string.
    static func display(for song: Song) -> String {
        credits(for: song).map(\.name).joined(separator: ", ")
    }

    static func display(albumArtist: String?, artists: [ArtistRef]?) -> String {
        if let artists, !artists.isEmpty {
            return artists.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return split(albumArtist ?? "").joined(separator: ", ")
    }

    /// Individual credits for tappable artist names.
    static func credits(for song: Song) -> [ArtistCredit] {
        if let artists = song.artists, !artists.isEmpty {
            let mapped = artists.compactMap { ref -> ArtistCredit? in
                let name = ref.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let id = ref.artistId?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ArtistCredit(name: name, artistId: (id?.isEmpty == false) ? id : nil)
            }
            if !mapped.isEmpty { return mapped }
        }
        let names = split(song.artist ?? "")
        if names.isEmpty { return [] }
        // Single primary artistId only attaches to the first parsed name.
        return names.enumerated().map { index, name in
            ArtistCredit(
                name: name,
                artistId: index == 0 ? song.artistId.flatMap { $0.isEmpty ? nil : $0 } : nil
            )
        }
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
