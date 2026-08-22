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
    private var pendingDeepLink: URL?
    private(set) var isHandlingDeepLink = false

    init() {
        accounts = AccountStore()
        database = AppDatabase.makeShared()
        AppEnvironment.shared = self
        SharePlayRuntime.shared.startListening()
        if let account = accounts.activeAccount {
            activate(account)
        }
    }

    func activate(_ account: Account) {
        guard let password = accounts.password(for: account) else { return }
        session?.teardown()
        session = AppSession(account: account, password: password, database: database)
        SharePlayRuntime.shared.bind(session?.player)
        accounts.setActive(account)
        NotificationCenter.default.post(name: .dromeSessionChanged, object: nil)
        #if os(iOS)
        consumePendingDeepLink()
        #endif
    }

    func signIn(account: Account, password: String) {
        accounts.add(account, password: password)
        activate(account)
    }

    func signOut() {
        SharePlayRuntime.shared.bind(nil)
        session?.teardown()
        session = nil
        accounts.setActive(nil)
        NotificationCenter.default.post(name: .dromeSessionChanged, object: nil)
    }

    #if os(iOS)
    func handleDeepLink(_ url: URL) {
        pendingDeepLink = url
        isHandlingDeepLink = true
        guard session != nil else { return }
        Task { await playDeepLink(url) }
    }

    func consumePendingOpen() {
        guard session != nil, !isHandlingDeepLink else { return }
        guard MessagesShareBridge.peekPendingOpen() != nil else { return }
        isHandlingDeepLink = true
        Task { await playDeepLink(nil) }
    }

    private func consumePendingDeepLink() {
        guard let url = pendingDeepLink else { return }
        pendingDeepLink = nil
        Task { await playDeepLink(url) }
    }

    private func playDeepLink(_ url: URL?) async {
        defer {
            pendingDeepLink = nil
            isHandlingDeepLink = false
        }
        guard let session else { return }
        let pending = MessagesShareBridge.consumePendingOpen()
        var songId = url.flatMap { DeepLink.songID(from: $0) } ?? pending?.id
        if songId == nil, let url, DeepLink.isShareCard(url) {
            songId = await fetchShareSongID(from: url)
        }
        guard let songId, !songId.isEmpty else { return }
        do {
            let song = try await session.client.song(id: songId)
            session.player.play(
                [song], startAt: 0,
                context: PlaybackContext(label: song.title, kind: .search))
            NowPlayingPresenter.open()
        } catch {
            guard let pending, pending.id == songId else { return }
            let song = Song(
                id: pending.id,
                title: pending.title.isEmpty ? "Track" : pending.title,
                album: pending.album.isEmpty ? nil : pending.album,
                albumId: nil,
                artist: pending.artist.isEmpty ? nil : pending.artist,
                artistId: nil,
                artists: nil,
                track: nil,
                discNumber: nil,
                year: nil,
                genre: nil,
                coverArt: pending.coverArt,
                size: nil,
                suffix: nil,
                duration: nil,
                bitRate: nil,
                samplingRate: nil,
                bitDepth: nil,
                contentType: nil,
                path: nil,
                playCount: nil,
                userRating: nil,
                starred: nil,
                created: nil)
            session.player.play(
                [song], startAt: 0,
                context: PlaybackContext(label: song.title, kind: .search))
            NowPlayingPresenter.open()
        }
    }

    private func fetchShareSongID(from url: URL) async -> String? {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        guard var infoURL = comps?.url else { return nil }
        // Strip /cover if a cover URL was somehow opened.
        if infoURL.lastPathComponent == "cover" {
            infoURL.deleteLastPathComponent()
        }
        var request = URLRequest(url: infoURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Info: Decodable { var songId: String }
        return try? JSONDecoder().decode(Info.self, from: data).songId
    }
    #endif

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
    let database: AppDatabase
    let library: LibraryIndex
    let ratings: RatingsStore
    let rotation: RotationManager
    let downloads: DownloadManager
    let player: PlayerEngine
    let lyricsService: LyricsService
    let lyricsIndexer: LyricsIndexer
    let artistImages: ArtistImageStore
    let connectivity: ConnectivityMonitor
    let connect: ConnectController?
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

    var connectClient: DromeConnectClient? {
        account.wishlistURL.map { url in
            let connectConfig = URLSessionConfiguration.default
            connectConfig.timeoutIntervalForRequest = 12
            connectConfig.timeoutIntervalForResource = 20
            let connectSession = URLSession(
                configuration: connectConfig,
                delegate: account.allowSelfSigned
                    ? ServerTrustDelegate(trustedHost: url.host)
                    : nil,
                delegateQueue: nil)
            return DromeConnectClient(baseURL: url, session: connectSession,
                               authItems: { [client] in client.authQueryItems() })
        }
    }

    init(account: Account, password: String, database: AppDatabase) {
        self.account = account
        self.database = database
        library = LibraryIndex(database: database)
        client = SubsonicClient(account: account, password: password)
        ratings = RatingsStore(client: client, database: database, userKey: account.userKey)
        rotation = RotationManager(client: client, database: database, userKey: account.userKey)
        ratings.rotation = rotation
        downloads = DownloadManager(client: client, database: database, serverKey: account.serverKey)
        player = PlayerEngine(client: client, ratings: ratings, rotation: rotation, downloads: downloads)
        if let wishlistURL = account.wishlistURL {
            // Short timeouts so a wedged companion can't stall the Connect loop for minutes.
            let connectConfig = URLSessionConfiguration.default
            connectConfig.timeoutIntervalForRequest = 12
            connectConfig.timeoutIntervalForResource = 20
            let connectSession = URLSession(
                configuration: connectConfig,
                delegate: account.allowSelfSigned
                    ? ServerTrustDelegate(trustedHost: wishlistURL.host)
                    : nil,
                delegateQueue: nil)
            let connectClient = DromeConnectClient(
                baseURL: wishlistURL,
                session: connectSession,
                authItems: { [client] in client.authQueryItems() })
            let controller = ConnectController(client: connectClient, player: player)
            connect = controller
            controller.start()
        } else {
            connect = nil
        }
        let userKey = account.userKey
        let sessionStore = PlaybackSessionStore(userKey: userKey)
        player.attachSessionStore(sessionStore)
        // Restore last queue into the mini player (paused) after first paint.
        // Hold off while a Messages deep link is in flight so we don't paint
        // an empty Now Playing or overwrite the card's track.
        Task { @MainActor [player] in
            await Task.yield()
            var spins = 0
            while AppEnvironment.shared.isHandlingDeepLink, spins < 25 {
                try? await Task.sleep(nanoseconds: 80_000_000)
                spins += 1
            }
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
        connect?.stop()
        player.shutdown()
        lyricsIndexer.stop()
        downloads.invalidate()
    }
}
