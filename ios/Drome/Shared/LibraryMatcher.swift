import Foundation

/// Title/artist normalization and ownership checks shared by Spotify search,
/// missing-tracks recommendations, and wishlist import filtering.
enum LibraryMatcher {
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        for token in ["(feat.", "(ft.", "(with ", "- remaster", "(remaster", "[remaster"] {
            if let range = s.range(of: token) {
                s = String(s[..<range.lowerBound])
            }
        }
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        s = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return s
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func ownedKeys(from songs: [Song]) -> Set<String> {
        var keys = Set<String>()
        for song in songs {
            let title = normalize(song.title)
            guard !title.isEmpty else { continue }
            keys.insert(title)
            let artist = normalize(song.displayArtist)
            if !artist.isEmpty {
                keys.insert("\(title)|\(artist)")
            }
        }
        return keys
    }

    static func looksOwned(title: String, artist: String, owned: Set<String>) -> Bool {
        let titleKey = normalize(title)
        guard !titleKey.isEmpty else { return false }
        if owned.contains(titleKey) { return true }
        let artistKey = normalize(artist)
        if !artistKey.isEmpty, owned.contains("\(titleKey)|\(artistKey)") { return true }
        if !artistKey.isEmpty {
            let artistToken = artistKey.split(separator: " ").first.map(String.init) ?? artistKey
            for key in owned where key.contains("|") {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0] == titleKey, parts[1].contains(artistToken) || artistKey.contains(parts[1]) {
                    return true
                }
            }
        }
        return false
    }

    static func looksOwned(_ hit: SpotifySearchHit, owned: Set<String>) -> Bool {
        looksOwned(title: hit.title, artist: hit.artist, owned: owned)
    }

    /// Best library song matching a Spotify hit via Subsonic search3.
    static func matchedSong(for hit: SpotifySearchHit, client: SubsonicClient) async -> Song? {
        let query = [hit.title, hit.artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return nil }
        do {
            let result = try await client.search(query, artistCount: 0, albumCount: 0, songCount: 12)
            let owned = ownedKeys(from: result.songs)
            guard looksOwned(hit, owned: owned) else { return nil }
            let titleKey = normalize(hit.title)
            let artistKey = normalize(hit.artist)
            return result.songs.first { song in
                let t = normalize(song.title)
                guard t == titleKey else { return false }
                if artistKey.isEmpty { return true }
                let a = normalize(song.displayArtist)
                return a.contains(artistKey) || artistKey.contains(a)
                    || a.split(separator: " ").first.map(String.init) == artistKey.split(separator: " ").first.map(String.init)
            } ?? result.songs.first { normalize($0.title) == titleKey }
        } catch {
            return nil
        }
    }

    static func matchedAlbum(for hit: SpotifySearchHit, client: SubsonicClient) async -> Album? {
        let query = [hit.title, hit.artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return nil }
        do {
            let result = try await client.search(query, artistCount: 0, albumCount: 12, songCount: 0)
            let titleKey = normalize(hit.title)
            let artistKey = normalize(hit.artist)
            return result.albums.first { album in
                guard normalize(album.name) == titleKey else { return false }
                if artistKey.isEmpty { return true }
                let a = normalize(album.artist ?? "")
                return a.contains(artistKey) || artistKey.contains(a)
            }
        } catch {
            return nil
        }
    }
}
