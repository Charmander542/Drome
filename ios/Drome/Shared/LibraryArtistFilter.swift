import Foundation

/// How often an artist appears as a primary vs credited contributor in the local index.
struct ArtistOwnership: Equatable, Sendable {
    var primarySongCount: Int = 0
    var creditSongCount: Int = 0
    var albumArtistAlbumCount: Int = 0
}

/// User preference + rules for hiding junk artists (feature credits, ghost entries).
enum LibraryArtistFilter {
    private static let hideKey = "drome.hideCreditOnlyArtists"
    static let preferenceDidChange = Notification.Name("drome.libraryArtistFilterDidChange")

    /// When on, artists with no albums who never headlined a song/album are hidden.
    static var hideCreditOnlyArtists: Bool {
        get {
            if UserDefaults.standard.object(forKey: hideKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: hideKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hideKey)
            NotificationCenter.default.post(name: preferenceDidChange, object: nil)
        }
    }

    static func isVisible(
        _ artist: Artist,
        ownership: ArtistOwnership?,
        songsIndexed: Bool
    ) -> Bool {
        guard hideCreditOnlyArtists else { return true }

        if (artist.albumCount ?? 0) > 0 { return true }

        guard let ownership, songsIndexed else {
            // Before the song index is ready, drop 0-album artists — they're usually junk.
            return false
        }

        if ownership.albumArtistAlbumCount > 0 { return true }
        if ownership.primarySongCount > 0 { return true }
        return false
    }

    static func filter(
        _ artists: [Artist],
        ownership: [String: ArtistOwnership],
        songsIndexed: Bool
    ) -> [Artist] {
        artists.filter { isVisible($0, ownership: ownership[$0.id], songsIndexed: songsIndexed) }
    }
}
