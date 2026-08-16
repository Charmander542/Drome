import Foundation
import Intents

/// Shared “play this in Drome” resolver for App Intents and SiriKit Media.
@MainActor
enum DromeSiriPlayback {
    enum Outcome: Equatable {
        case played(title: String, artist: String?)
        case wishlisted(title: String, artist: String?)
        case notSignedIn
        case notFound(query: String)
        case wishlistFailed(String)

        var spoken: String {
            switch self {
            case .played(let title, let artist):
                if let artist, !artist.isEmpty {
                    return "Playing \(title) by \(artist)."
                }
                return "Playing \(title)."
            case .wishlisted(let title, let artist):
                if let artist, !artist.isEmpty {
                    return "That’s not in your library. I added \(title) by \(artist) to your wishlist."
                }
                return "That’s not in your library. I added \(title) to your wishlist."
            case .notSignedIn:
                return "Open Drome and sign in first."
            case .notFound(let query):
                return "I couldn’t find \(query) in Drome."
            case .wishlistFailed(let message):
                return message
            }
        }
    }

    static func perform(query: String, artist: String? = nil, album: String? = nil) async -> Outcome {
        let items = await resolveMediaItems(query: query, artist: artist, album: album)
        guard let first = items.first else {
            if AppEnvironment.shared?.session == nil { return .notSignedIn }
            return .notFound(query: query)
        }
        return await handle(mediaItems: [first])
    }

    static func resolveMediaItems(query: String, artist: String? = nil, album: String? = nil) async -> [INMediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let session = AppEnvironment.shared?.session else { return [] }

        let searchQuery = [trimmed, artist, album]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if let match = await resolveLibrary(
            session: session, query: searchQuery, titleHint: trimmed,
            artistHint: artist, albumHint: album)
        {
            return [match.mediaItem]
        }

        if let wishlist = session.wishlist,
           let hits = try? await wishlist.search(query: searchQuery, types: "track", limit: 5),
           let hit = hits.first(where: { $0.kind == "track" }) ?? hits.first {
            return [INMediaItem(
                identifier: "wishlist:" + hit.spotifyUrl,
                title: hit.title,
                type: .song,
                artwork: nil,
                artist: hit.artist)]
        }
        return []
    }

    static func handle(mediaItems: [INMediaItem]) async -> Outcome {
        guard let session = AppEnvironment.shared?.session else { return .notSignedIn }
        guard let item = mediaItems.first else {
            return .notFound(query: "that")
        }
        guard let identifier = item.identifier, !identifier.isEmpty else {
            return .notFound(query: item.title ?? "that")
        }

        if identifier.hasPrefix("wishlist:") {
            let url = String(identifier.dropFirst("wishlist:".count))
            guard let wishlist = session.wishlist else {
                return .notFound(query: item.title ?? "that")
            }
            do {
                _ = try await wishlist.add(spotifyLink: url)
                return .wishlisted(title: item.title ?? "that track", artist: item.artist)
            } catch {
                return .wishlistFailed(error.localizedDescription)
            }
        }

        if identifier.hasPrefix("album:") {
            let id = String(identifier.dropFirst("album:".count))
            guard let album = try? await session.client.album(id: id), !album.songs.isEmpty else {
                return .notFound(query: item.title ?? "that album")
            }
            session.player.play(
                album.songs, startAt: 0,
                context: PlaybackContext(label: album.name, kind: .album(id: album.id)))
            return .played(title: album.name, artist: album.artist)
        }

        if identifier.hasPrefix("artist:") {
            let name = item.artist ?? item.title ?? String(identifier.dropFirst("artist:".count))
            guard let songs = try? await session.client.topSongs(artistName: name), !songs.isEmpty else {
                return .notFound(query: name)
            }
            let artistId = String(identifier.dropFirst("artist:".count))
            session.player.play(
                songs, startAt: 0,
                context: PlaybackContext(label: name, kind: .artist(id: artistId)))
            return .played(title: name, artist: name)
        }

        let songId = identifier.hasPrefix("song:") ? String(identifier.dropFirst("song:".count)) : identifier
        guard let song = try? await session.client.song(id: songId) else {
            return .notFound(query: item.title ?? "that")
        }
        session.player.play(
            [song], startAt: 0,
            context: PlaybackContext(label: song.title, kind: .search))
        return .played(title: song.title, artist: song.displayArtist)
    }

    private struct LibraryMatch {
        var mediaItem: INMediaItem
    }

    private static func resolveLibrary(
        session: AppSession,
        query: String,
        titleHint: String,
        artistHint: String?,
        albumHint: String?
    ) async -> LibraryMatch? {
        let result = try? await session.client.search(
            query, artistCount: 8, albumCount: 8, songCount: 24)
        guard let result else { return nil }

        let titleKey = LibraryMatcher.normalize(titleHint)
        let artistKey = LibraryMatcher.normalize(artistHint ?? "")
        let albumKey = LibraryMatcher.normalize(albumHint ?? "")

        if let song = bestSong(result.songs, titleKey: titleKey, artistKey: artistKey) {
            return LibraryMatch(mediaItem: INMediaItem(
                identifier: "song:" + song.id,
                title: song.title,
                type: .song,
                artwork: nil,
                artist: song.displayArtist))
        }

        if let album = bestAlbum(result.albums, nameKey: albumKey.isEmpty ? titleKey : albumKey, artistKey: artistKey) {
            return LibraryMatch(mediaItem: INMediaItem(
                identifier: "album:" + album.id,
                title: album.name,
                type: .album,
                artwork: nil,
                artist: album.artist))
        }

        if let artist = bestArtist(result.artists, nameKey: artistKey.isEmpty ? titleKey : artistKey) {
            return LibraryMatch(mediaItem: INMediaItem(
                identifier: "artist:" + artist.id,
                title: artist.name,
                type: .artist,
                artwork: nil,
                artist: artist.name))
        }

        return nil
    }

    private static func bestSong(_ songs: [Song], titleKey: String, artistKey: String) -> Song? {
        var best: (Song, Int)?
        for song in songs {
            let t = LibraryMatcher.normalize(song.title)
            var score = 0
            if t == titleKey { score = 100 }
            else if !titleKey.isEmpty, t.contains(titleKey) || titleKey.contains(t) { score = 55 }
            else { continue }
            if !artistKey.isEmpty {
                let a = LibraryMatcher.normalize(song.displayArtist)
                if a == artistKey { score += 40 }
                else if a.contains(artistKey) || artistKey.contains(a) { score += 20 }
            }
            if best == nil || score > best!.1 { best = (song, score) }
        }
        guard let best, best.1 >= 55 else { return nil }
        return best.0
    }

    private static func bestAlbum(_ albums: [Album], nameKey: String, artistKey: String) -> Album? {
        guard !nameKey.isEmpty else { return nil }
        var best: (Album, Int)?
        for album in albums {
            let n = LibraryMatcher.normalize(album.name)
            var score = 0
            if n == nameKey { score = 100 }
            else if n.contains(nameKey) || nameKey.contains(n) { score = 60 }
            else { continue }
            if !artistKey.isEmpty {
                let a = LibraryMatcher.normalize(album.artist ?? "")
                if a.contains(artistKey) || artistKey.contains(a) { score += 20 }
            }
            if best == nil || score > best!.1 { best = (album, score) }
        }
        guard let best, best.1 >= 60 else { return nil }
        return best.0
    }

    private static func bestArtist(_ artists: [Artist], nameKey: String) -> Artist? {
        guard !nameKey.isEmpty else { return nil }
        return artists.first { LibraryMatcher.normalize($0.name) == nameKey }
            ?? artists.first {
                let n = LibraryMatcher.normalize($0.name)
                return n.contains(nameKey) || nameKey.contains(n)
            }
    }
}
