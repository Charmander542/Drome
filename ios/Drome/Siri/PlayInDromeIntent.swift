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
    }
}
