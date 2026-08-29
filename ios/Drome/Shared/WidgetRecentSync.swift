import Foundation
import UIKit
import WidgetKit
import Combine

/// Main-app writer — builds widget snapshot from play history and live playback.
enum WidgetRecentSync {
    private static var playbackCancellable: AnyCancellable?
    private static var transportCancellable: AnyCancellable?
    private static var trackChangeCancellable: AnyCancellable?
    private static var lastNowPlayingSignature: String?

    static func refresh(session: AppSession, database: AppDatabase) {
        Task { @MainActor in
            await perform(session: session, database: database)
        }
    }

    @MainActor
    static func bindPlayback(session: AppSession, database: AppDatabase) {
        transportCancellable = transportUpdates(session)
            .sink { _ in
                PhoneWatchSession.shared.broadcast(
                    session: session,
                    database: database,
                    priority: .transport)
            }

        playbackCancellable = Publishers.CombineLatest(
            session.player.clock.$elapsed,
            session.player.clock.$duration
        )
        .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
        .sink { _, _ in
            PhoneWatchSession.shared.broadcast(
                session: session,
                database: database,
                priority: .playhead)
        }

        trackChangeCancellable = session.player.$current
            .removeDuplicates { $0?.song.id == $1?.song.id }
            .sink { current in
                guard let current else { return }
                Task { @MainActor in
                    await prefetchArtForWatch(session: session, database: database, song: current.song)
                }
            }
    }

    @MainActor
    private static func transportUpdates(_ session: AppSession) -> AnyPublisher<Void, Never> {
        let local = Publishers.Merge(
            session.player.$isPlaying.removeDuplicates().map { _ in () },
            session.player.$current
                .removeDuplicates { $0?.song.id == $1?.song.id }
                .map { _ in () }
        )
        guard let connect = session.connect else {
            return local.eraseToAnyPublisher()
        }
        let remote = connect.objectWillChange
            .map { transportIsPlaying(session: session, localPlaying: session.player.isPlaying) }
            .removeDuplicates()
            .map { _ in () }
        return Publishers.Merge(local, remote).eraseToAnyPublisher()
    }

    @MainActor
    private static func prefetchArtForWatch(
        session: AppSession,
        database: AppDatabase,
        song: Song
    ) async {
        guard let artDir = WidgetRecentStore.artDirectoryURL else { return }
        _ = await cacheArt(
            id: "song-\(song.id)",
            remote: session.artworkURL(for: song, size: 300),
            artDir: artDir)
        guard session.player.current?.song.id == song.id else { return }
        await syncNowPlaying(
            session: session,
            database: database,
            current: session.player.current,
            isPlaying: session.player.isPlaying,
            elapsed: session.player.accurateElapsed(),
            duration: session.player.clock.duration)
        // Art may have landed after transport-only updates; force a widget pass.
        writeNowPlayingSnapshot(session: session, database: database)
        PhoneWatchSession.shared.broadcast(
            session: session,
            database: database,
            priority: .full)
    }

    /// Writes live player state to the shared widget snapshot (no Watch push).
    @MainActor
    static func writeNowPlayingSnapshot(session: AppSession, database: AppDatabase) {
        guard WidgetRecentStore.artDirectoryURL != nil else { return }

        var snapshot = WidgetRecentStore.load()
        snapshot.updatedAt = Date().timeIntervalSince1970
        let player = session.player

        if let current = player.current {
            let song = current.song
            let art = resolveNowPlayingArt(songId: song.id, in: snapshot)
            let wash: (r: Double, g: Double, b: Double)
            if let art {
                wash = WidgetArtWash.fromArtworkFile(art)
            } else if let prior = snapshot.nowPlaying, prior.songId == song.id {
                wash = (prior.washR, prior.washG, prior.washB)
            } else {
                wash = (0.22, 0.20, 0.19)
            }
            let playing = transportIsPlaying(session: session, localPlaying: player.isPlaying)
            let prior = snapshot.nowPlaying
            let pausedSince: TimeInterval?
            if playing {
                pausedSince = nil
            } else if prior?.songId != song.id || prior?.isPlaying == true || prior?.pausedSince == nil {
                pausedSince = Date().timeIntervalSince1970
            } else {
                pausedSince = prior?.pausedSince
            }
            snapshot.nowPlaying = WidgetNowPlaying(
                songId: song.id,
                title: song.title,
                artist: song.artist ?? "",
                artworkFile: art,
                isPlaying: playing,
                elapsed: player.accurateElapsed(),
                duration: player.clock.duration > 0
                    ? player.clock.duration
                    : TimeInterval(song.duration ?? 0),
                capturedAt: Date().timeIntervalSince1970,
                rating: session.ratings.rating(for: song),
                isOutOfRotation: session.rotation.contains(song.id),
                washR: wash.r, washG: wash.g, washB: wash.b,
                pausedSince: pausedSince)
        } else {
            snapshot.nowPlaying = nil
        }

        WidgetRecentStore.save(snapshot)
        reloadWidgetTimelinesIfNeeded(for: snapshot)
    }

    /// Reload home-screen widget timelines when live playback state changes.
    @MainActor
    private static func reloadWidgetTimelinesIfNeeded(for snapshot: WidgetRecentSnapshot) {
        let signature = [
            snapshot.nowPlaying?.songId,
            snapshot.nowPlaying?.artworkFile ?? "none",
            snapshot.nowPlaying.map { $0.isPlaying ? "1" : "0" },
            snapshot.nowPlaying.map { np in
                np.isPlaying ? String(Int(np.elapsed / 3)) : "0"
            },
        ].compactMap { $0 }.joined(separator: "|")
        if signature != lastNowPlayingSignature {
            lastNowPlayingSignature = signature
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Prefer snapshot art for the current song, then fall back to App Group cache.
    @MainActor
    private static func resolveNowPlayingArt(songId: String, in snapshot: WidgetRecentSnapshot) -> String? {
        if snapshot.nowPlaying?.songId == songId,
           let file = snapshot.nowPlaying?.artworkFile,
           !file.isEmpty {
            return file
        }
        return cachedArtFilename(forSongId: songId)
    }

    private static func cachedArtFilename(forSongId songId: String) -> String? {
        cachedArtFilename(id: "song-\(songId)")
    }

    private static func cachedArtFilename(id: String) -> String? {
        let filename = sanitized(id) + ".jpg"
        guard let url = WidgetRecentStore.artworkURL(for: filename),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return filename
    }

    /// Immediate snapshot from live player (no network) for Watch command replies.
    @MainActor
    static func flushNowPlayingForWatch(session: AppSession, database: AppDatabase) {
        writeNowPlayingSnapshot(session: session, database: database)
        PhoneWatchSession.shared.broadcast(
            session: session,
            database: database,
            priority: .full)
    }

    @MainActor
    private static func transportIsPlaying(session: AppSession, localPlaying: Bool) -> Bool {
        if session.connect?.isRemote == true {
            return session.connect?.remoteSession?.isPlaying == true
        }
        return localPlaying
    }

    @MainActor
    private static func perform(session: AppSession, database: AppDatabase) async {
        let userKey = session.account.userKey
        let entries = (try? database.recentPlayEntries(userKey: userKey, limit: 12)) ?? []
        guard let artDir = WidgetRecentStore.artDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)

        var items: [WidgetRecentItem] = []
        for entry in entries.prefix(8) {
            guard let item = await item(for: entry, session: session, artDir: artDir) else { continue }
            items.append(item)
        }

        let existing = WidgetRecentStore.load()
        let snapshot = WidgetRecentSnapshot(
            updatedAt: Date().timeIntervalSince1970,
            items: items,
            nowPlaying: existing.nowPlaying)
        WidgetRecentStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        PhoneWatchSession.shared.broadcast(
            session: session,
            database: database,
            priority: .full)
    }

    @MainActor
    private static func syncNowPlaying(session: AppSession,
                                       database: AppDatabase,
                                       current: QueueItem?,
                                       isPlaying: Bool,
                                       elapsed: TimeInterval,
                                       duration: TimeInterval) async {
        guard let artDir = WidgetRecentStore.artDirectoryURL else { return }

        var snapshot = WidgetRecentStore.load()
        snapshot.updatedAt = Date().timeIntervalSince1970

        if let current {
            let song = current.song
            let art: String?
            if snapshot.nowPlaying?.songId == song.id,
               let existing = snapshot.nowPlaying?.artworkFile,
               !existing.isEmpty {
                art = existing
            } else {
                art = await cacheArt(
                    id: "song-\(song.id)",
                    remote: session.artworkURL(for: song, size: 300),
                    artDir: artDir)
            }
            let wash: (r: Double, g: Double, b: Double)
            if let art {
                wash = WidgetArtWash.fromArtworkFile(art)
            } else if let prior = snapshot.nowPlaying, prior.songId == song.id {
                wash = (prior.washR, prior.washG, prior.washB)
            } else {
                wash = (0.22, 0.20, 0.19)
            }
            let playing = transportIsPlaying(session: session, localPlaying: isPlaying)
            let playhead = elapsed
            let prior = snapshot.nowPlaying
            let pausedSince: TimeInterval?
            if playing {
                pausedSince = nil
            } else if prior?.songId != song.id || prior?.isPlaying == true || prior?.pausedSince == nil {
                pausedSince = Date().timeIntervalSince1970
            } else {
                pausedSince = prior?.pausedSince
            }
            snapshot.nowPlaying = WidgetNowPlaying(
                songId: song.id,
                title: song.title,
                artist: song.artist ?? "",
                artworkFile: art,
                isPlaying: playing,
                elapsed: playhead,
                duration: duration > 0 ? duration : TimeInterval(song.duration ?? 0),
                capturedAt: Date().timeIntervalSince1970,
                rating: session.ratings.rating(for: song),
                isOutOfRotation: session.rotation.contains(song.id),
                washR: wash.r, washG: wash.g, washB: wash.b,
                pausedSince: pausedSince)
        } else {
            snapshot.nowPlaying = nil
        }

        WidgetRecentStore.save(snapshot)
        reloadWidgetTimelinesIfNeeded(for: snapshot)
        PhoneWatchSession.shared.broadcast(
            session: session,
            database: database,
            priority: .full)
    }

    @MainActor
    private static func item(for entry: RecentPlayEntry,
                             session: AppSession,
                             artDir: URL) async -> WidgetRecentItem? {
        let resumeKey = resumeKey(for: entry)
        let coverSong = coverSong(for: entry)
        let rating = session.ratings.rating(for: coverSong)

        switch entry {
        case .song(let song):
            let art = await cacheArt(
                id: "song-\(song.id)",
                remote: session.artworkURL(for: song, size: 300),
                artDir: artDir)
            return WidgetRecentItem(
                id: entry.id,
                title: song.title,
                subtitle: song.artist ?? "",
                artworkFile: art,
                resumeKey: resumeKey,
                deepLink: WidgetDeepLink.play(resumeKey: resumeKey, entryId: entry.id, songId: song.id),
                rating: rating)

        case .album(_, let name, let coverSong):
            let art = await cacheArt(
                id: "album-\(entry.id)",
                remote: session.artworkURL(for: coverSong, size: 300),
                artDir: artDir)
            return WidgetRecentItem(
                id: entry.id,
                title: name,
                subtitle: coverSong.artist ?? "Album",
                artworkFile: art,
                resumeKey: resumeKey,
                deepLink: WidgetDeepLink.play(resumeKey: resumeKey, entryId: entry.id, songId: coverSong.id),
                rating: rating)

        case .playlist(_, let name, let coverSong):
            let art = await cacheArt(
                id: "playlist-\(entry.id)",
                remote: session.artworkURL(for: coverSong, size: 300),
                artDir: artDir)
            return WidgetRecentItem(
                id: entry.id,
                title: name,
                subtitle: "Playlist",
                artworkFile: art,
                resumeKey: resumeKey,
                deepLink: WidgetDeepLink.play(resumeKey: resumeKey, entryId: entry.id, songId: coverSong.id),
                rating: rating)

        case .mix(_, let name, let coverSong, let subtitle):
            let art = await cacheArt(
                id: "mix-\(entry.id)",
                remote: session.artworkURL(for: coverSong, size: 300),
                artDir: artDir)
            return WidgetRecentItem(
                id: entry.id,
                title: name,
                subtitle: subtitle,
                artworkFile: art,
                resumeKey: resumeKey,
                deepLink: WidgetDeepLink.play(resumeKey: resumeKey, entryId: entry.id, songId: coverSong.id),
                rating: rating)
        }
    }

    private static func coverSong(for entry: RecentPlayEntry) -> Song {
        switch entry {
        case .song(let song): return song
        case .album(_, _, let song): return song
        case .playlist(_, _, let song): return song
        case .mix(_, _, let song, _): return song
        }
    }

    private static func resumeKey(for entry: RecentPlayEntry) -> String {
        switch entry {
        case .song(let song):
            return "song:\(song.id)"
        case .album(let id, _, _):
            return "album:\(id)"
        case .playlist(let id, _, _):
            return "playlist:\(id)"
        case .mix(let key, let name, let coverSong, let subtitle):
            if key.hasPrefix("genre:") { return "genre:\(name)" }
            if key.hasPrefix("artist:") {
                return "artist:\(coverSong.artistId ?? name)"
            }
            if key.hasPrefix("outOfRotation") || name == RotationManager.playlistName {
                return "outOfRotation"
            }
            if subtitle == "Daily Mix" || name.hasPrefix("Daily Mix") {
                return "mix:\(name)"
            }
            return "mix:\(name)"
        }
    }

    private static func cacheArt(id: String, remote: URL?, artDir: URL) async -> String? {
        let filename = sanitized(id) + ".jpg"
        let dest = artDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) { return filename }
        guard let remote else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: remote),
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.82)
        else { return nil }
        try? jpeg.write(to: dest, options: .atomic)
        return filename
    }

    private static func sanitized(_ raw: String) -> String {
        raw.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}
