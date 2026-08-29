import AppIntents

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

    func suggestedEntities() async throws -> [DromePlayRequest] {
        []
    }
}

struct PlayInDromeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play in Drome"
    static var description = IntentDescription(
        "Play a song, album, or artist from your Drome library. If it isn’t there, Drome adds it to your wishlist.")
    static var openAppWhenRun = true

    @Parameter(title: "Song", requestValueDialog: "What do you want to play?")
    var song: DromePlayRequest

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$song) in Drome")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await DromeSiriPlayback.perform(query: song.id)
        return .result(dialog: IntentDialog(stringLiteral: outcome.spoken))
    }
}

struct DromeShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .orange }

    /// Listed statically so compile-time metadata extraction can register them (dynamic arrays export zero shortcuts).
    /// iOS allows at most 10 App Shortcuts.
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayInDromeIntent(),
            phrases: [
                "Play \(\.$song) in \(.applicationName)",
                "Play \(\.$song) with \(.applicationName)",
                "Play the song \(\.$song) in \(.applicationName)",
                "Ask \(.applicationName) to play \(\.$song)",
            ],
            shortTitle: "Play in Drome",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayFourStarsAndUpIntent(),
            phrases: [
                "Play 4 stars and up in \(.applicationName)",
                "Play four stars and up in \(.applicationName)",
                "Play my highly rated music in \(.applicationName)",
            ],
            shortTitle: "Play 4 Stars & Up",
            systemImageName: "star.leadinghalf.filled"
        )
        AppShortcut(
            intent: PlayRandomIntent(),
            phrases: [
                "Play random in \(.applicationName)",
                "Shuffle my library in \(.applicationName)",
                "Play something random in \(.applicationName)",
            ],
            shortTitle: "Play Random",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayMostRecentIntent(),
            phrases: [
                "Play most recent in \(.applicationName)",
                "Resume in \(.applicationName)",
                "Continue listening in \(.applicationName)",
            ],
            shortTitle: "Play Most Recent",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: PlayHypeIntent(),
            phrases: [
                "Play Hype in \(.applicationName)",
                "Start Hype in \(.applicationName)",
                "Play the Hype vibe in \(.applicationName)",
            ],
            shortTitle: "Play Hype",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: PlayChillIntent(),
            phrases: [
                "Play Chill in \(.applicationName)",
                "Start Chill in \(.applicationName)",
                "Play the Chill vibe in \(.applicationName)",
            ],
            shortTitle: "Play Chill",
            systemImageName: "leaf"
        )
        AppShortcut(
            intent: PlayFeelGoodIntent(),
            phrases: [
                "Play Feel-Good in \(.applicationName)",
                "Play Feel Good in \(.applicationName)",
                "Start Feel-Good in \(.applicationName)",
            ],
            shortTitle: "Play Feel-Good",
            systemImageName: "sun.max.fill"
        )
        AppShortcut(
            intent: PlayLateNightIntent(),
            phrases: [
                "Play Late Night in \(.applicationName)",
                "Start Late Night in \(.applicationName)",
                "Play the Late Night vibe in \(.applicationName)",
            ],
            shortTitle: "Play Late Night",
            systemImageName: "moon.stars.fill"
        )
        AppShortcut(
            intent: PlayFocusIntent(),
            phrases: [
                "Play Focus in \(.applicationName)",
                "Start Focus in \(.applicationName)",
                "Play the Focus vibe in \(.applicationName)",
            ],
            shortTitle: "Play Focus",
            systemImageName: "metronome.fill"
        )
        AppShortcut(
            intent: PlayHeartbreakIntent(),
            phrases: [
                "Play Heartbreak in \(.applicationName)",
                "Start Heartbreak in \(.applicationName)",
                "Play the Heartbreak vibe in \(.applicationName)",
            ],
            shortTitle: "Play Heartbreak",
            systemImageName: "heart.fill"
        )
    }
}
