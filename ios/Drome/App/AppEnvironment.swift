import Foundation
import SwiftUI

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
    }

    func signIn(account: Account, password: String) {
        accounts.add(account, password: password)
        activate(account)
    }

    func signOut() {
        session?.teardown()
        session = nil
        accounts.setActive(nil)
    }

    func remove(_ account: Account) {
        if session?.account.id == account.id {
            session?.teardown()
            session = nil
        }
        accounts.remove(account)
        if let next = accounts.activeAccount {
            activate(next)
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

    var id: UUID { account.id }

    var wishlist: DromeWishlistClient? {
        account.wishlistURL.map { url in
            DromeWishlistClient(baseURL: url, session: client.session,
                                authItems: { [client] in client.authQueryItems() })
        }
    }

    init(account: Account, password: String, database: AppDatabase) {
        self.account = account
        client = SubsonicClient(account: account, password: password)
        ratings = RatingsStore(client: client)
        rotation = RotationManager(client: client, database: database, userKey: account.userKey)
        ratings.rotation = rotation
        downloads = DownloadManager(client: client, database: database, serverKey: account.serverKey)
        player = PlayerEngine(client: client, ratings: ratings, rotation: rotation, downloads: downloads)
        player.autoplayProvider = AutoplayProvider(client: client, ratings: ratings, rotation: rotation)
        lyricsService = LyricsService(database: database, client: client, serverKey: account.serverKey)
        lyricsIndexer = LyricsIndexer(client: client, database: database,
                                      lyricsService: lyricsService, serverKey: account.serverKey)

        ImageLoader.shared.session = client.session
        Task { await rotation.refresh() }
        lyricsIndexer.start()
    }

    func teardown() {
        player.shutdown()
        lyricsIndexer.stop()
        downloads.invalidate()
    }
}
