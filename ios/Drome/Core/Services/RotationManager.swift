import Foundation

/// Manages the per-user `Out of Rotation` system playlist.
///
/// Rules:
/// - Rating a track 2★ or lower automatically adds it (created on first use).
/// - Raising the rating above 2★ removes it again, but only if the system
///   added it — manual membership always wins.
/// - Manually removing a low-rated track records a `manual_remove` override
///   so the automation never re-adds it.
/// - Tracks in the playlist stay fully playable on demand; they are only
///   excluded from shuffle and autoplay candidate pools.
@MainActor
final class RotationManager: ObservableObject {
    static let playlistName = "Out of Rotation"

    @Published private(set) var songIDs: Set<String> = []
    @Published private(set) var playlist: Playlist?

    private let client: SubsonicClient
    private let database: AppDatabase
    private let userKey: String

    init(client: SubsonicClient, database: AppDatabase, userKey: String) {
        self.client = client
        self.database = database
        self.userKey = userKey
    }

    func isSystemPlaylist(_ playlist: Playlist) -> Bool {
        playlist.name == Self.playlistName
    }

    func contains(_ songId: String) -> Bool {
        songIDs.contains(songId)
    }

    /// The exclusion set for shuffle/autoplay pools.
    var excludedIDs: Set<String> { songIDs }

    func refresh() async {
        do {
            let lists = try await client.playlists()
            if let existing = lists.first(where: {
                $0.name == Self.playlistName &&
                ($0.owner == nil || $0.owner == client.account.username)
            }) {
                playlist = existing
                let full = try await client.playlist(id: existing.id)
                songIDs = Set(full.songs.map(\.id))
            } else {
                playlist = nil
                songIDs = []
            }
        } catch {
            // Leave last known state; rotation is best-effort.
        }
    }

    private func ensurePlaylistID() async throws -> String {
        if let playlist { return playlist.id }
        let created = try await client.createPlaylist(name: Self.playlistName)
        try? await client.updatePlaylist(
            id: created.id,
            comment: "Managed by Drome — tracks rated 2 stars or lower are excluded from shuffle and autoplay. Manual adds/removes always win.")
        playlist = created.asPlaylist
        return created.id
    }

    func add(_ song: Song, manual: Bool) async {
        await addAll([song], manual: manual)
    }

    /// Bulk-add tracks to Out of Rotation (e.g. whole playlist).
    func addAll(_ songs: [Song], manual: Bool) async {
        let unique = songs.filter { !songIDs.contains($0.id) }
        guard !unique.isEmpty else { return }
        do {
            let playlistID = try await ensurePlaylistID()
            var index = 0
            while index < unique.count {
                let end = min(index + 40, unique.count)
                let chunk = Array(unique[index..<end])
                try await client.updatePlaylist(id: playlistID, addSongIds: chunk.map(\.id))
                for song in chunk {
                    songIDs.insert(song.id)
                    try? database.setRotationOverride(
                        userKey: userKey, songId: song.id,
                        kind: manual ? "manual_add" : "auto")
                }
                index = end
            }
        } catch {}
    }

    func remove(_ song: Song, manual: Bool) async {
        guard let playlist else { return }
        do {
            let full = try await client.playlist(id: playlist.id)
            let indices = full.songs.enumerated()
                .filter { $0.element.id == song.id }
                .map(\.offset)
            if !indices.isEmpty {
                try await client.updatePlaylist(id: playlist.id, removeIndices: indices)
            }
            songIDs.remove(song.id)
            if manual {
                try? database.setRotationOverride(userKey: userKey, songId: song.id, kind: "manual_remove")
            } else {
                try? database.clearRotationOverride(userKey: userKey, songId: song.id)
            }
        } catch {}
    }

    func ratingDidChange(song: Song, rating: Int) async {
        let override = (try? database.rotationOverride(userKey: userKey, songId: song.id)) ?? nil
        if (1...2).contains(rating) {
            guard override != "manual_remove" else { return }
            await add(song, manual: false)
        } else {
            // Rating raised (or cleared): only undo automatic additions.
            if songIDs.contains(song.id), override == "auto" {
                await remove(song, manual: false)
            }
        }
    }
}
