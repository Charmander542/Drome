import AppIntents
import Foundation

// MARK: - Playback commands

@MainActor
enum DromePlaybackCommands {
    enum Result: Equatable {
        case started(String)
        case notSignedIn
        case empty(String)

        var spoken: String {
            switch self {
            case .started(let label): return "Playing \(label)."
            case .notSignedIn: return "Open Drome and sign in first."
            case .empty(let reason): return reason
            }
        }
    }

    static func playFourStarsAndUp() async -> Result {
        await playRatedCollection(.fourPlus)
    }

    static func playRandom() async -> Result {
        guard let session = AppEnvironment.shared?.session else { return .notSignedIn }
        var songs = (try? await session.client.randomSongs(size: 80)) ?? []
        if songs.isEmpty {
            songs = (try? await session.client.randomSongs(size: 80)) ?? []
        }
        guard !songs.isEmpty else {
            return .empty("Your library is empty.")
        }
        session.player.shuffleMode = .random
        session.player.play(
            songs, startAt: 0,
            context: PlaybackContext(label: "Random", kind: .mix))
        return .started("random tracks from your library")
    }

    static func play(vibe: MoodVibe) async -> Result {
        guard let session = AppEnvironment.shared?.session else { return .notSignedIn }
        await MoodPlayer.play(vibe, session: session)
        guard session.player.current != nil else {
            return .empty("Couldn't start \(vibe.title).")
        }
        return .started(vibe.title)
    }

    static func playMostRecent() async -> Result {
        guard let env = AppEnvironment.shared, let session = env.session else {
            return .notSignedIn
        }
        let userKey = session.account.userKey
        guard let entry = try? env.database.recentPlayEntries(userKey: userKey, limit: 1).first else {
            return .empty("Nothing recently played yet.")
        }
        let label = recentLabel(entry)
        guard await play(entry: entry, session: session) else {
            return .empty("Couldn't resume \(label).")
        }
        return .started(label)
    }

    private static func playRatedCollection(_ collection: RatedCollection) async -> Result {
        guard let session = AppEnvironment.shared?.session else { return .notSignedIn }
        let minRating: Int
        switch collection {
        case .fiveStars: minRating = 5
        case .fourPlus, .topAlbums: minRating = 4
        }
        var songs = session.ratings.cachedSongs(minRating: minRating)
        if songs.isEmpty {
            await session.ratings.discoverFromServer()
            songs = session.ratings.cachedSongs(minRating: minRating)
        }
        guard !songs.isEmpty else {
            return .empty("No \(collection.rawValue.lowercased()) tracks yet.")
        }
        session.player.play(
            songs, startAt: 0,
            context: PlaybackContext(label: collection.rawValue, kind: .mix))
        return .started(collection.rawValue)
    }

    private static func recentLabel(_ entry: RecentPlayEntry) -> String {
        switch entry {
        case .song(let song): return song.title
        case .album(_, let name, _): return name
        case .playlist(_, let name, _): return name
        case .mix(_, let name, _, _): return name
        }
    }

    @discardableResult
    private static func play(entry: RecentPlayEntry, session: AppSession) async -> Bool {
        let player = session.player
        switch entry {
        case .song(let song):
            if player.resumeSession(forKey: "song:\(song.id)") { return true }
            if let albumId = song.albumId, player.resumeSession(forKey: "album:\(albumId)") { return true }
            player.play([song], startAt: 0,
                        context: PlaybackContext(label: song.title, kind: .search))
            return true

        case .playlist(let id, let name, let coverSong):
            if player.resumeSession(forKey: "playlist:\(id)") { return true }
            guard let playlist = try? await session.client.playlist(id: id),
                  !playlist.songs.isEmpty else { return false }
            LibraryDetailCache.store(playlist: playlist)
            let start = playlist.songs.firstIndex(where: { $0.id == coverSong.id }) ?? 0
            let kind: PlaybackContext.Kind = playlist.name == RotationManager.playlistName
                ? .outOfRotation
                : .playlist(id: id)
            player.play(playlist.songs, startAt: start,
                        context: PlaybackContext(label: name, kind: kind))
            return true

        case .album(let id, let name, let coverSong):
            if player.resumeSession(forKey: "album:\(id)") { return true }
            guard let album = try? await session.client.album(id: id),
                  !album.songs.isEmpty else { return false }
            let start = album.songs.firstIndex(where: { $0.id == coverSong.id }) ?? 0
            player.play(album.songs, startAt: start,
                        context: PlaybackContext(label: name, kind: .album(id: id)))
            return true

        case .mix(let key, let name, let coverSong, let subtitle):
            if key.hasPrefix("genre:") {
                if player.resumeSession(forKey: "genre:\(name)") { return true }
                let songs = (try? await session.client.songsByGenre(name, count: 200)) ?? []
                guard !songs.isEmpty else { return false }
                player.play(songs, startAt: 0,
                            context: PlaybackContext(label: name, kind: .genre))
                return true
            }
            if key.hasPrefix("artist:"), let artistId = coverSong.artistId {
                if player.resumeSession(forKey: "artist:\(artistId)") { return true }
                let songs = (try? await session.client.topSongs(artistName: name, count: 40)) ?? []
                guard !songs.isEmpty else { return false }
                player.play(songs, startAt: 0,
                            context: PlaybackContext(label: name, kind: .artist(id: artistId)))
                return true
            }
            if key.hasPrefix("outOfRotation") || name == RotationManager.playlistName {
                if player.resumeSession(forKey: "outOfRotation") { return true }
                if let playlistID = session.rotation.playlist?.id,
                   player.resumeSession(forKey: "playlist:\(playlistID)") { return true }
                return false
            }
            if let vibe = MoodVibe.allCases.first(where: {
                $0.title == name || ($0 == .lucky && name.localizedCaseInsensitiveContains("lucky"))
            }) {
                await MoodPlayer.play(vibe, session: session)
                return player.current != nil
            }
            if player.resumeSession(forKey: "mix:\(name)") { return true }
            if subtitle == "Daily Mix" || name.hasPrefix("Daily Mix") {
                return false
            }
            return false
        }
    }
}

// MARK: - Intents

struct PlayFourStarsAndUpIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play 4 Stars and Up"
    static var description = IntentDescription("Shuffle tracks you've rated four stars or higher.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.playFourStarsAndUp()
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

struct PlayRandomIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Random"
    static var description = IntentDescription("Shuffle random tracks from your library.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.playRandom()
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

struct PlayHypeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Hype"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.play(vibe: .hype)
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

struct PlayChillIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Chill"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.play(vibe: .chill)
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

struct PlayFeelGoodIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Feel-Good"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.play(vibe: .feelGood)
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

struct PlayLateNightIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Late Night"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.play(vibe: .lateNight)
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

struct PlayFocusIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Focus"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.play(vibe: .focus)
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

struct PlayHeartbreakIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Heartbreak"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.play(vibe: .heartbreak)
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

struct PlayLuckyIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Lucky"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.play(vibe: .lucky)
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

// MARK: - Mood App Shortcuts (one tile per station)

struct PlayMostRecentIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Most Recent"
    static var description = IntentDescription("Resume your most recently played album, playlist, or mix.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.playMostRecent()
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}
