import Foundation

/// User-tunable playback preferences persisted in UserDefaults.
@MainActor
enum PlaybackPreferences {
    private static let skipLowRatedKey = "drome.skipLowRatedEverywhere"
    private static let recencyHoursKey = "drome.autoplayRecencyHours"
    private static let compressCellularKey = "drome.compressOnCellular"
    private static let resilientStreamingKey = "drome.resilientStreaming"
    /// Posted when stream-format prefs change so the player can rebuild.
    static let streamPreferenceDidChange = Notification.Name("drome.streamPreferenceDidChange")

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

    /// On cellular, request a server-side MP3 transcode instead of raw FLAC.
    /// Defaults on — saves data; turn off for lossless over LTE.
    static var compressOnCellular: Bool {
        get {
            if UserDefaults.standard.object(forKey: compressCellularKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: compressCellularKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: compressCellularKey)
            NotificationCenter.default.post(name: streamPreferenceDidChange, object: nil)
        }
    }

    /// Prefer compressed + disk-cached streams when the Navidrome host is not on
    /// the local LAN (Tailscale / public URL). Survives Wi‑Fi ↔ LTE handoffs.
    /// Defaults on — turn off only if you want lossless over VPN.
    static var resilientRemoteStreaming: Bool {
        get {
            if UserDefaults.standard.object(forKey: resilientStreamingKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: resilientStreamingKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: resilientStreamingKey)
            NotificationCenter.default.post(name: streamPreferenceDidChange, object: nil)
        }
    }

    /// Cellular / remote stream bitrate (kbps) when compression is on.
    static var cellularMaxBitRate: Int { 256 }

    /// True when `host` looks like a LAN address (not Tailscale CGNAT / public).
    static func isLocalNetworkHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") { return true }
        // Tailscale MagicDNS / CGNAT — treat as remote.
        if lower.hasSuffix(".ts.net") || lower.hasSuffix(".tailscale.net") { return false }
        if lower.hasPrefix("100.") { return false } // Tailscale CGNAT 100.64/10 (approx)

        let parts = lower.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 127 { return true }
        return false
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
