import Foundation
import SwiftUI
import Combine

/// Composition root. Owns the account store and the currently active session;
/// switching accounts tears down one session and builds another, so all
/// per-user state (player, ratings, rotation, downloads) stays independent.
@MainActor
final class AppEnvironment: ObservableObject {
    static private(set) var shared: AppEnvironment!

    let accounts: AccountStore
    let database: AppDatabase

    @Published private(set) var session: AppSession?

    init() {
        accounts = AccountStore()
        database = AppDatabase.makeShared()
        AppEnvironment.shared = self
        if let account = accounts.activeAccount {
            activate(account)
        }
    }

    func activate(_ account: Account) {
        guard let password = accounts.password(for: account) else { return }
        session?.teardown()
        session = AppSession(account: account, password: password, database: database)
        accounts.setActive(account)
        NotificationCenter.default.post(name: .dromeSessionChanged, object: nil)
    }

    func signIn(account: Account, password: String) {
        accounts.add(account, password: password)
        activate(account)
    }

    func signOut() {
        session?.teardown()
        session = nil
        accounts.setActive(nil)
        NotificationCenter.default.post(name: .dromeSessionChanged, object: nil)
    }

    func remove(_ account: Account) {
        if session?.account.id == account.id {
            session?.teardown()
            session = nil
        }
        accounts.remove(account)
        if let next = accounts.activeAccount {
            activate(next)
        } else {
            NotificationCenter.default.post(name: .dromeSessionChanged, object: nil)
        }
    }
}

/// Everything scoped to one signed-in Navidrome user.
@MainActor
final class AppSession: ObservableObject, Identifiable {
    let account: Account
    let client: SubsonicClient
    let ratings: RatingsStore
    let rotation: RotationManager
    let downloads: DownloadManager
    let player: PlayerEngine
    let lyricsService: LyricsService
    let lyricsIndexer: LyricsIndexer
    let artistImages: ArtistImageStore
    let connectivity: ConnectivityMonitor
    private var playbackSideEffectCancellables = Set<AnyCancellable>()

    var id: UUID { account.id }

    /// Prefer locally downloaded cover art when present (offline-safe).
    func artworkURL(id: String?, size: Int = 600) -> URL? {
        if let local = downloads.localCoverURL(coverId: id) { return local }
        return client.coverArtURL(id: id, size: size)
    }

    func artworkURL(for song: Song, size: Int = 600) -> URL? {
        artworkURL(id: song.coverArt ?? song.albumId ?? song.id, size: size)
    }

    var wishlist: DromeWishlistClient? {
        account.wishlistURL.map { url in
            DromeWishlistClient(baseURL: url, session: client.session,
                                authItems: { [client] in client.authQueryItems() })
        }
    }

    init(account: Account, password: String, database: AppDatabase) {
        self.account = account
        client = SubsonicClient(account: account, password: password)
        ratings = RatingsStore(client: client, database: database, userKey: account.userKey)
        rotation = RotationManager(client: client, database: database, userKey: account.userKey)
        ratings.rotation = rotation
        downloads = DownloadManager(client: client, database: database, serverKey: account.serverKey)
        player = PlayerEngine(client: client, ratings: ratings, rotation: rotation, downloads: downloads)
        let userKey = account.userKey
        let sessionStore = PlaybackSessionStore(userKey: userKey)
        player.attachSessionStore(sessionStore)
        // Restore last queue into the mini player (paused) after first paint.
        Task { @MainActor [player] in
            await Task.yield()
            _ = player.restorePersistedSessionIfNeeded()
        }
        // History writes must never contend with the audio render path.
        player.onTrackStarted = { [player] song in
            let context = player.context
            Task.detached(priority: .utility) {
                try? database.recordPlay(userKey: userKey, song: song, context: context)
            }
        }
        player.autoplayProvider = AutoplayProvider(
            client: client, ratings: ratings, rotation: rotation,
            database: database, userKey: userKey)
        lyricsService = LyricsService(database: database, client: client, serverKey: account.serverKey)
        lyricsIndexer = LyricsIndexer(client: client, database: database,
                                      lyricsService: lyricsService, serverKey: account.serverKey)
        artistImages = ArtistImageStore(database: database, serverKey: account.serverKey)
        connectivity = ConnectivityMonitor()

        ImageLoader.shared.session = client.session
        Task { await rotation.refresh() }
        lyricsIndexer.start()

        // Pause library lyrics crawling while audio is playing so indexing
        // network I/O cannot starve the stream.
        player.$isPlaying
            .removeDuplicates()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak lyricsIndexer] playing in
                guard let lyricsIndexer else { return }
                if playing {
                    lyricsIndexer.stop()
                } else if lyricsIndexer.isEnabled {
                    lyricsIndexer.start()
                }
            }
            .store(in: &playbackSideEffectCancellables)
    }

    func teardown() {
        playbackSideEffectCancellables.removeAll()
        player.shutdown()
        lyricsIndexer.stop()
        downloads.invalidate()
    }
}
