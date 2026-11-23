import AppIntents
import Foundation

// MARK: - Song / artist / album request

/// Spoken title/artist/album name, wrapped so App Shortcuts can bind it.
struct DromePlayRequest: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Song"
    static var defaultQuery = DromePlayRequestQuery()

    var id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: id))
    }
}

struct DromePlayRequestQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DromePlayRequest] {
        identifiers.map { DromePlayRequest(id: $0) }
    }

    func entities(matching string: String) async throws -> [DromePlayRequest] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [DromePlayRequest(id: trimmed)]
    }

    /// Recent plays so Spotlight / Siri can suggest real library titles.
    func suggestedEntities() async throws -> [DromePlayRequest] {
        await MainActor.run {
            guard let env = AppEnvironment.shared,
                  let session = env.session,
                  let entries = try? env.database.recentPlayEntries(
                    userKey: session.account.userKey, limit: 12)
            else { return [] }

            var seen = Set<String>()
            var out: [DromePlayRequest] = []
            for entry in entries {
                let label: String
                switch entry {
                case .song(let song):
                    let artist = song.displayArtist
                    label = artist.isEmpty ? song.title : "\(song.title) by \(artist)"
                case .album(_, let name, _):
                    label = name
                case .playlist(_, let name, _):
                    label = name
                case .mix(_, let name, _, _):
                    label = name
                }
                let key = label.lowercased()
                guard seen.insert(key).inserted else { continue }
                out.append(DromePlayRequest(id: label))
                if out.count >= 8 { break }
            }
            return out
        }
    }
}

struct PlayInDromeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play in Drome"
    static var description = IntentDescription(
        "Play a song, album, or artist from your Drome library. If it isn’t there, Drome adds it to your wishlist.")
    /// Keep the shell warm so audio starts like Spotify without a cold launch flash when possible.
    static var openAppWhenRun = true

    @Parameter(title: "Song", requestValueDialog: "What do you want to play?")
    var song: DromePlayRequest

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$song) on Drome")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await DromeSiriPlayback.perform(query: song.id)
        return .result(dialog: IntentDialog(stringLiteral: outcome.spoken))
    }
}

// MARK: - Vibe entity

struct DromeVibeEntity: AppEntity, Equatable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Vibe"
    static var defaultQuery = DromeVibeEntityQuery()

    var id: String
    var title: String
    var symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            image: .init(systemName: symbol))
    }

    var mood: MoodVibe? { MoodVibe(rawValue: id) }

    static func from(_ vibe: MoodVibe) -> DromeVibeEntity {
        DromeVibeEntity(id: vibe.rawValue, title: vibe.title, symbol: vibe.symbol)
    }
}

struct DromeVibeEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DromeVibeEntity] {
        identifiers.compactMap { id in
            MoodVibe(rawValue: id).map(DromeVibeEntity.from)
        }
    }

    func suggestedEntities() async throws -> [DromeVibeEntity] {
        MoodVibe.allCases.map(DromeVibeEntity.from)
    }
}

extension DromeVibeEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [DromeVibeEntity] {
        let key = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        return MoodVibe.allCases
            .filter {
                $0.title.lowercased().contains(key)
                    || $0.shortLabel.lowercased().contains(key)
                    || $0.rawValue.contains(key)
            }
            .map(DromeVibeEntity.from)
    }
}

struct PlayVibeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play a Vibe"
    static var description = IntentDescription(
        "Start a Drome vibe station — Hype, Chill, Feel-Good, Late Night, Focus, Heartbreak, or Lucky.")
    static var openAppWhenRun = true

    @Parameter(title: "Vibe", requestValueDialog: "Which vibe?")
    var vibe: DromeVibeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$vibe) on Drome")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let mood = vibe.mood else {
            return .result(dialog: "I don’t know that vibe.")
        }
        let result = await DromePlaybackCommands.play(vibe: mood)
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

// MARK: - Playlist entity

struct DromePlaylistEntity: AppEntity, Equatable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static var defaultQuery = DromePlaylistEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct DromePlaylistEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DromePlaylistEntity] {
        let all = await loadPlaylists()
        let wanted = Set(identifiers)
        return all.filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [DromePlaylistEntity] {
        // Cap suggestions so phrase expansion stays well under the 1,000 limit.
        Array(await loadPlaylists().prefix(8))
    }

    private func loadPlaylists() async -> [DromePlaylistEntity] {
        await MainActor.run {
            guard let session = AppEnvironment.shared?.session else { return [] }
            let cached = LibraryListCatalog.playlists(serverKey: session.account.serverKey) ?? []
            let filtered = cached.filter { $0.name != RotationManager.playlistName }
            if !filtered.isEmpty {
                return filtered.map { DromePlaylistEntity(id: $0.id, name: $0.name) }
            }
            return []
        }
    }
}

extension DromePlaylistEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [DromePlaylistEntity] {
        let key = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        let cached = try await suggestedEntities().filter { $0.name.lowercased().contains(key) }
        if !cached.isEmpty { return cached }
        return await liveMatch(key: key)
    }

    private func liveMatch(key: String) async -> [DromePlaylistEntity] {
        let session = await MainActor.run { AppEnvironment.shared?.session }
        guard let session else { return [] }
        let lists = (try? await session.client.playlists()) ?? []
        return lists
            .filter {
                $0.name != RotationManager.playlistName
                    && $0.name.lowercased().contains(key)
            }
            .prefix(8)
            .map { DromePlaylistEntity(id: $0.id, name: $0.name) }
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play a Playlist"
    static var description = IntentDescription("Play one of your Drome playlists.")
    static var openAppWhenRun = true

    @Parameter(title: "Playlist", requestValueDialog: "Which playlist?")
    var playlist: DromePlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist) on Drome")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await DromePlaybackCommands.playPlaylist(id: playlist.id, name: playlist.name)
        return .result(dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

// MARK: - App Shortcuts (Spotify-style: few, memorable, parameterized)

struct DromeShortcuts: AppShortcutsProvider {
    /// Warm amber tile — matches Drome’s default accent.
    static var shortcutTileColor: ShortcutTileColor { .orange }

    /// iOS allows at most 10. Prefer parameterized phrases over one tile per vibe.
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayInDromeIntent(),
            phrases: [
                "Play \(\.$song) on \(.applicationName)",
                "Play \(\.$song) in \(.applicationName)",
                "Play \(\.$song) with \(.applicationName)",
                "Ask \(.applicationName) to play \(\.$song)",
                "Put on \(\.$song) in \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayVibeIntent(),
            phrases: [
                "Play \(\.$vibe) on \(.applicationName)",
                "Play \(\.$vibe) in \(.applicationName)",
                "Start \(\.$vibe) on \(.applicationName)",
                "Put on \(\.$vibe) in \(.applicationName)",
            ],
            shortTitle: "Play a Vibe",
            systemImageName: "dial.low.fill"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) on \(.applicationName)",
                "Play \(\.$playlist) in \(.applicationName)",
                "Play my \(\.$playlist) playlist on \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PlayFourStarsAndUpIntent(),
            phrases: [
                "Play my liked songs on \(.applicationName)",
                "Play liked songs on \(.applicationName)",
                "Play 4 stars and up in \(.applicationName)",
                "Play four stars and up in \(.applicationName)",
                "Play my highly rated music in \(.applicationName)",
            ],
            shortTitle: "Liked Songs",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: PlayRandomIntent(),
            phrases: [
                "Shuffle on \(.applicationName)",
                "Shuffle my library on \(.applicationName)",
                "Play random in \(.applicationName)",
                "Play something random in \(.applicationName)",
                "Surprise me on \(.applicationName)",
            ],
            shortTitle: "Shuffle",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayMostRecentIntent(),
            phrases: [
                "Continue on \(.applicationName)",
                "Resume on \(.applicationName)",
                "Continue listening on \(.applicationName)",
                "Play most recent in \(.applicationName)",
                "Pick up where I left off on \(.applicationName)",
            ],
            shortTitle: "Continue",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: PlayLuckyIntent(),
            phrases: [
                "Play Lucky on \(.applicationName)",
                "Feeling lucky on \(.applicationName)",
                "Surprise me with Lucky on \(.applicationName)",
            ],
            shortTitle: "Lucky",
            systemImageName: "dice.fill"
        )
    }
}
