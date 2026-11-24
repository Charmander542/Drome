import Foundation
import UIKit
import WidgetKit
import Combine

/// Main-app writer — builds widget snapshot from play history and live playback.
enum WidgetRecentSync {
    private static var playbackCancellable: AnyCancellable?
    private static var transportCancellable: AnyCancellable?
    private static var trackChangeCancellable: AnyCancellable?

    /// In-memory mirror of the App Group snapshot. The app is the only writer,
    /// so reads never need to touch the shared container after the first load.
    private static var cachedSnapshot: WidgetRecentSnapshot?
    private static var lastSnapshotWriteAt: TimeInterval = 0
    private static var washCache: [String: (r: Double, g: Double, b: Double)] = [:]
    /// Serial so snapshot files always land in the order they were produced.
    private static let ioQueue = DispatchQueue(label: "com.drome.widget-snapshot", qos: .utility)

    /// Widget + Watch extrapolate the playhead from `capturedAt`, so while the
    /// app is on screen a steady stream only needs a periodic refresh to stay
    /// inside `WidgetRecentSnapshot.staleSyncInterval`.
    private static let foregroundRefreshInterval: TimeInterval = 45
    /// Home / Lock Screen widgets can be visible once the app is backgrounded —
    /// keep their progress bar moving at the cadence it always had.
    private static let backgroundRefreshInterval: TimeInterval = 3
    /// Seeks / stalls larger than this are pushed immediately.
    private static let playheadDriftTolerance: TimeInterval = 1.5

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
            // Fires twice a second while audio plays — stay off the disk
            // unless the widget / Watch would actually show something new.
            guard playheadNeedsSync(session: session) else { return }
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

    /// Snapshot as last written by this process (loads the file once).
    @MainActor
    static func currentSnapshot() -> WidgetRecentSnapshot {
        if let cachedSnapshot { return cachedSnapshot }
        let loaded = WidgetRecentStore.load()
        cachedSnapshot = loaded
        return loaded
    }

    @MainActor
    private static var playingRefreshInterval: TimeInterval {
        UIApplication.shared.applicationState == .active
            ? foregroundRefreshInterval
            : backgroundRefreshInterval
    }

    /// Cheap check for the playhead tick: true only when the stored snapshot
    /// no longer predicts what the player is doing.
    @MainActor
    private static func playheadNeedsSync(session: AppSession) -> Bool {
        guard let cached = cachedSnapshot else { return true }
        let player = session.player
        guard let current = player.current else { return cached.nowPlaying != nil }
        guard let stored = cached.nowPlaying, stored.songId == current.song.id else { return true }

        let playing = transportIsPlaying(session: session, localPlaying: player.isPlaying)
        if stored.isPlaying != playing { return true }
        if stored.rating != session.ratings.rating(for: current.song) { return true }
        if stored.isOutOfRotation != session.rotation.contains(current.song.id) { return true }

        let now = Date().timeIntervalSince1970
        if playing, now - lastSnapshotWriteAt >= playingRefreshInterval { return true }

        let duration = player.clock.duration > 0
            ? player.clock.duration
            : TimeInterval(current.song.duration ?? 0)
        if abs(stored.duration - duration) > 1 { return true }

        let predicted = stored.isPlaying
            ? stored.elapsed + (now - stored.capturedAt)
            : stored.elapsed
        return abs(predicted - player.accurateElapsed()) > playheadDriftTolerance
    }

    /// True when `new` shows something a reader could not derive from `old`.
    private static func isMeaningfulChange(
        from old: WidgetNowPlaying?,
        to new: WidgetNowPlaying?
    ) -> Bool {
        guard let old, let new else { return (old == nil) != (new == nil) }
        if old.songId != new.songId
            || old.isPlaying != new.isPlaying
            || old.artworkFile != new.artworkFile
            || old.title != new.title
            || old.artist != new.artist
            || old.rating != new.rating
            || old.isOutOfRotation != new.isOutOfRotation
            || old.pausedSince != new.pausedSince {
            return true
        }
        if abs(old.duration - new.duration) > 1 { return true }
        if abs(old.washR - new.washR) > 0.001
            || abs(old.washG - new.washG) > 0.001
            || abs(old.washB - new.washB) > 0.001 {
            return true
        }
        let predicted = old.isPlaying
            ? old.elapsed + (new.capturedAt - old.capturedAt)
            : old.elapsed
        return abs(predicted - new.elapsed) > playheadDriftTolerance
    }

    /// Updates the in-memory snapshot, then writes the shared file and reloads
    /// widget timelines off the main thread.
    @MainActor
    private static func store(_ snapshot: WidgetRecentSnapshot) {
        cachedSnapshot = snapshot
        lastSnapshotWriteAt = snapshot.updatedAt
        ioQueue.async {
            WidgetRecentStore.save(snapshot)
            // After the write so the widget never reloads against a stale file.
            DispatchQueue.main.async {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    /// Wash colors are derived from the cached cover file — decode it once per cover.
    @MainActor
    private static func wash(forArtworkFile file: String) -> (r: Double, g: Double, b: Double) {
        if let cached = washCache[file] { return cached }
        let wash = WidgetArtWash.fromArtworkFile(file)
        if washCache.count >= 48 { washCache.removeAll(keepingCapacity: true) }
        washCache[file] = wash
        return wash
    }

    /// Writes live player state to the shared widget snapshot (no Watch push).
    /// Returns `false` when the stored snapshot already describes the player.
    @MainActor
    @discardableResult
    static func writeNowPlayingSnapshot(session: AppSession, database: AppDatabase) -> Bool {
        let previous = currentSnapshot()
        var snapshot = previous
        let now = Date().timeIntervalSince1970
        snapshot.updatedAt = now
        let player = session.player

        if let current = player.current {
            let song = current.song
            let art = resolveNowPlayingArt(songId: song.id, in: snapshot)
            let wash: (r: Double, g: Double, b: Double)
            if let art {
                wash = self.wash(forArtworkFile: art)
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
                pausedSince = now
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
                capturedAt: now,
                rating: session.ratings.rating(for: song),
                isOutOfRotation: session.rotation.contains(song.id),
                washR: wash.r, washG: wash.g, washB: wash.b,
                pausedSince: pausedSince)
        } else {
            snapshot.nowPlaying = nil
        }

        let changed = isMeaningfulChange(from: previous.nowPlaying, to: snapshot.nowPlaying)
        let refreshDue = snapshot.nowPlaying?.isPlaying == true
            && now - lastSnapshotWriteAt >= playingRefreshInterval
        guard changed || refreshDue else { return false }

        store(snapshot)
        return true
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
        let entries = await Task.detached(priority: .utility) {
            (try? database.recentPlayEntries(userKey: userKey, limit: 12)) ?? []
        }.value
        guard let artDir = WidgetRecentStore.artDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)

        var items: [WidgetRecentItem] = []
        for entry in entries.prefix(8) {
            guard let item = await item(for: entry, session: session, artDir: artDir) else { continue }
            items.append(item)
        }

        let existing = currentSnapshot()
        let snapshot = WidgetRecentSnapshot(
            updatedAt: Date().timeIntervalSince1970,
            items: items,
            nowPlaying: existing.nowPlaying)
        store(snapshot)
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

        var snapshot = currentSnapshot()
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
                wash = self.wash(forArtworkFile: art)
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

        store(snapshot)
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
