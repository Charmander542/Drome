import SwiftUI

/// Resolves and caches Spotify artist photos for list/detail UIs.
@MainActor
final class ArtistImageStore: ObservableObject {
    private let database: AppDatabase
    private let serverKey: String
    private var memory: [String: URL] = [:]
    private var inflight: [String: Task<URL?, Never>] = [:]

    init(database: AppDatabase, serverKey: String) {
        self.database = database
        self.serverKey = serverKey
    }

    /// Memory-only — never hits SQLite on the main/render path.
    func memoryURL(artistId: String) -> URL? {
        memory[artistId]
    }

    func resolve(artistId: String, name: String, wishlist: DromeWishlistClient?) async -> URL? {
        if let cached = memory[artistId] { return cached }

        let key = serverKey
        let db = database
        let diskURL = await Task.detached(priority: .utility) { () -> URL? in
            guard let raw = try? db.artistImageURL(serverKey: key, artistId: artistId)
            else { return nil }
            return URL(string: raw)
        }.value
        if let diskURL {
            memory[artistId] = diskURL
            return diskURL
        }

        guard let wishlist, !name.isEmpty else { return nil }

        if let existing = inflight[artistId] {
            return await existing.value
        }
        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            do {
                let raw = try await wishlist.artistImageURL(name: name)
                guard let url = URL(string: raw) else { return nil }
                let key = self.serverKey
                let db = self.database
                await Task.detached(priority: .utility) {
                    try? db.storeArtistImage(
                        serverKey: key, artistId: artistId, artistName: name, imageURL: raw)
                }.value
                self.memory[artistId] = url
                return url
            } catch {
                return nil
            }
        }
        inflight[artistId] = task
        let url = await task.value
        inflight[artistId] = nil
        return url
    }
}

struct ArtistAvatar: View {
    let artistId: String
    let name: String
    var size: CGFloat = 48
    var navidromeCoverArt: String?
    /// Library lists should stay on Navidrome covers — Spotify lookup storms
    /// the network and thrash List cells while scrolling. Opt in on artist detail.
    var allowsSpotifyLookup: Bool = false

    @EnvironmentObject private var session: AppSession
    @State private var spotifyURL: URL?

    /// List-sized cover (≈2× point size) — small enough to feel instant.
    private var coverURL: URL? {
        session.client.coverArtURL(id: navidromeCoverArt ?? artistId, size: Int(max(size * 2, 96)))
    }

    var body: some View {
        Group {
            if let spotifyURL {
                RemoteImage(url: spotifyURL, placeholderSymbol: "person.crop.circle")
            } else {
                RemoteImage(url: coverURL, placeholderSymbol: "person.crop.circle")
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: artistId) {
            spotifyURL = session.artistImages.memoryURL(artistId: artistId)
            guard allowsSpotifyLookup, spotifyURL == nil else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            spotifyURL = await session.artistImages.resolve(
                artistId: artistId, name: name, wishlist: session.wishlist)
        }
    }
}
