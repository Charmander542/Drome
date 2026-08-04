import Foundation

/// Progressive background job that walks the library album by album and
/// caches lyrics for every track, building up the FTS index that powers deep
/// (lyrics) search. Resumable: progress is persisted per server, and the job
/// is polite to LRCLIB (small delay between network fetches).
@MainActor
final class LyricsIndexer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = ""
    @Published private(set) var cachedCount = 0

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "drome.lyricsIndexer") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "drome.lyricsIndexer")
            objectWillChange.send()
            if newValue { start() } else { stop() }
        }
    }

    private let client: SubsonicClient
    private let database: AppDatabase
    private let lyricsService: LyricsService
    private let serverKey: String
    private var task: Task<Void, Never>?

    init(client: SubsonicClient, database: AppDatabase,
         lyricsService: LyricsService, serverKey: String) {
        self.client = client
        self.database = database
        self.lyricsService = lyricsService
        self.serverKey = serverKey
        refreshCount()
    }

    func refreshCount() {
        cachedCount = (try? database.lyricsCount(serverKey: serverKey)) ?? 0
    }

    func start() {
        guard isEnabled, task == nil else { return }
        isRunning = true
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Restart indexing from the top of the library (e.g. after new imports).
    func reindexFromStart() {
        stop()
        try? database.setLyricsIndexOffset(serverKey: serverKey, offset: 0)
        start()
    }

    private func run() async {
        defer {
            isRunning = false
            task = nil
        }
        var offset = (try? database.lyricsIndexOffset(serverKey: serverKey)) ?? 0
        let pageSize = 20

        while !Task.isCancelled {
            let albums: [Album]
            do {
                albums = try await client.albumList(type: .alphabeticalByName,
                                                    size: pageSize, offset: offset)
            } catch {
                statusText = "Indexer paused (server unreachable)"
                return
            }
            if albums.isEmpty {
                statusText = "Library fully indexed"
                refreshCount()
                return
            }

            for album in albums {
                if Task.isCancelled { return }
                statusText = "Indexing \(album.name)"
                guard let full = try? await client.album(id: album.id) else { continue }
                for song in full.songs {
                    if Task.isCancelled { return }
                    if await lyricsService.isCached(song) { continue }
                    _ = await lyricsService.lyrics(for: song)
                    // Politeness delay so we never hammer LRCLIB/Navidrome.
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }

            offset += albums.count
            try? database.setLyricsIndexOffset(serverKey: serverKey, offset: offset)
            refreshCount()
        }
    }
}
