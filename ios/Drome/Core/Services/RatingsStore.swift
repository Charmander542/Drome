import Foundation

/// Client-side overlay of track ratings. Server objects carry `userRating`,
/// but after the user rates something we need every view (and the shuffle
/// weighting) to see the new value immediately without refetching.
@MainActor
final class RatingsStore: ObservableObject {
    @Published private(set) var ratings: [String: Int] = [:]

    private let client: SubsonicClient
    weak var rotation: RotationManager?

    init(client: SubsonicClient) {
        self.client = client
    }

    /// Seed the overlay from freshly fetched songs (server values win only
    /// when we have no local overlay yet).
    func ingest(_ songs: [Song]) {
        for song in songs {
            if let serverRating = song.userRating, ratings[song.id] == nil {
                ratings[song.id] = serverRating
            }
        }
    }

    func rating(for song: Song) -> Int {
        ratings[song.id] ?? song.userRating ?? 0
    }

    func rating(forID id: String) -> Int {
        ratings[id] ?? 0
    }

    /// Sets the rating (0 clears), syncs to the server, and triggers the
    /// automatic Out of Rotation logic.
    func setRating(_ rating: Int, for song: Song) async {
        let previous = self.rating(for: song)
        ratings[song.id] = rating
        do {
            try await client.setRating(id: song.id, rating: rating)
        } catch {
            ratings[song.id] = previous
            return
        }
        await rotation?.ratingDidChange(song: song, rating: rating)
    }
}
