import Foundation
import SwiftUI

/// Client-side overlay of track ratings (Subsonic `setRating`), backed by a
/// SQLite index so Rated collections stay stable across visits.
///
/// Session-scoped: a new `AppSession` (and thus a fresh store) is created per
/// account. Server ratings are per Navidrome user — there is no cross-account
/// cache.
///
/// Mutations always replace the dictionary (not in-place subscript) so
/// `@Published` reliably notifies SwiftUI. In-flight requests are coalesced
/// per song so rapid taps stay snappy and don't race.
@MainActor
final class RatingsStore: ObservableObject {
    @Published private(set) var ratings: [String: Int] = [:]
    /// Bumps on every visible rating change so views can key off it cheaply.
    @Published private(set) var revision: UInt64 = 0

    private let client: SubsonicClient
    private let database: AppDatabase
    private let userKey: String
    weak var rotation: RotationManager?
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var discoveryTask: Task<Void, Never>?

    init(client: SubsonicClient, database: AppDatabase, userKey: String) {
        self.client = client
        self.database = database
        self.userKey = userKey
        if let stored = try? database.allSongRatings(userKey: userKey) {
            ratings = stored
        }
    }

    func ingest(_ songs: [Song]) {
        var next = ratings
        var changed = false
        for song in songs {
            guard let serverRating = song.userRating, serverRating > 0 else { continue }
            // Never clobber a local rating the user already set this session /
            // persisted previously — local index is source of truth for UI.
            if next[song.id] == nil {
                next[song.id] = serverRating
                changed = true
            }
            let effective = next[song.id] ?? serverRating
            try? database.upsertSongRating(userKey: userKey, song: song, rating: effective)
        }
        guard changed else { return }
        ratings = next
        revision &+= 1
    }

    func rating(for song: Song) -> Int {
        ratings[song.id] ?? song.userRating ?? 0
    }

    func rating(forID id: String) -> Int {
        ratings[id] ?? 0
    }

    /// Instant Rated-folder contents from the local index (no network).
    func cachedSongs(minRating: Int) -> [Song] {
        (try? database.ratedSongs(userKey: userKey, minRating: minRating)) ?? []
    }

    func setRating(_ rating: Int, for song: Song) {
        let clamped = min(5, max(0, rating))
        let previous = self.rating(for: song)
        guard clamped != previous || ratings[song.id] == nil else { return }

        var next = ratings
        if clamped == 0 {
            next.removeValue(forKey: song.id)
        } else {
            next[song.id] = clamped
        }
        ratings = next
        revision &+= 1

        var snapshot = song
        snapshot.userRating = clamped == 0 ? nil : clamped
        if clamped == 0 {
            try? database.clearSongRating(userKey: userKey, songId: song.id)
        } else {
            try? database.upsertSongRating(userKey: userKey, song: snapshot, rating: clamped)
        }

        inFlight[song.id]?.cancel()
        let songID = song.id
        inFlight[songID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.setRating(id: songID, rating: clamped)
                guard !Task.isCancelled else { return }
                await self.rotation?.ratingDidChange(song: song, rating: clamped)
            } catch {
                guard !Task.isCancelled else { return }
                var rollback = self.ratings
                if previous == 0 {
                    rollback.removeValue(forKey: songID)
                    try? self.database.clearSongRating(userKey: self.userKey, songId: songID)
                } else {
                    rollback[songID] = previous
                    var rolled = song
                    rolled.userRating = previous
                    try? self.database.upsertSongRating(userKey: self.userKey, song: rolled, rating: previous)
                }
                self.ratings = rollback
                self.revision &+= 1
            }
            self.inFlight[songID] = nil
        }
    }

    /// Pulls highly rated albums / random samples from the server and merges
    /// any `userRating` values into the local index. Safe to call repeatedly.
    func discoverFromServer() async {
        if let discoveryTask {
            await discoveryTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let topAlbums = try await self.client.albumList(type: .highest, size: 40)
                for album in topAlbums.prefix(25) {
                    if Task.isCancelled { return }
                    let detail = try await self.client.album(id: album.id)
                    self.ingest(detail.songs)
                }
                for _ in 0..<3 {
                    if Task.isCancelled { return }
                    let batch = try await self.client.randomSongs(size: 100)
                    self.ingest(batch)
                }
            } catch {
                // Local index remains usable even if discovery fails.
            }
        }
        discoveryTask = task
        await task.value
        discoveryTask = nil
    }
}

// MARK: - Shared rating colors (1★ red → 5★ yellow)

enum RatingStyle {
    static func color(for rating: Int) -> Color {
        switch min(5, max(0, rating)) {
        case 1: return Color(red: 0.92, green: 0.22, blue: 0.24)
        case 2: return Color(red: 0.95, green: 0.42, blue: 0.16)
        case 3: return Color(red: 0.96, green: 0.62, blue: 0.12)
        case 4: return Color(red: 0.98, green: 0.78, blue: 0.14)
        case 5: return Color(red: 1.00, green: 0.86, blue: 0.18)
        default: return DromeTheme.muted
        }
    }
}
