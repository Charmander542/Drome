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

        // Disk lookup off the hot path (after scroll settle in the avatar).
        if let raw = try? database.artistImageURL(serverKey: serverKey, artistId: artistId),
           let url = URL(string: raw) {
            memory[artistId] = url
            return url
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
                try? self.database.storeArtistImage(
                    serverKey: self.serverKey, artistId: artistId, artistName: name, imageURL: raw)
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

    @EnvironmentObject private var session: AppSession
    @State private var spotifyURL: URL?

    var body: some View {
        Group {
            if let spotifyURL {
                RemoteImage(url: spotifyURL, placeholderSymbol: "person.crop.circle")
            } else {
                RemoteImage(
                    url: session.client.coverArtURL(id: navidromeCoverArt ?? artistId, size: Int(size * 2)),
                    placeholderSymbol: "person.crop.circle")
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: artistId) {
            // Show Navidrome cover immediately; only touch memory here.
            spotifyURL = session.artistImages.memoryURL(artistId: artistId)
            guard spotifyURL == nil else { return }
            // Defer Spotify / SQLite so fast flings cancel before work starts.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            spotifyURL = await session.artistImages.resolve(
                artistId: artistId, name: name, wishlist: session.wishlist)
        }
    }
}
