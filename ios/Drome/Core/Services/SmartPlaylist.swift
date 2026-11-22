import Foundation

/// Rule applied as AND against a candidate song pool.
enum SmartPlaylistRule: Hashable, Sendable {
    case minRating(Int)
    case maxRating(Int)
    case starred(Bool)
    case genreContains(String)
    case playedWithinDays(Int)
    case notPlayedWithinDays(Int)
    case yearAtLeast(Int)
    case yearAtMost(Int)
    case downloadedOnly
}

/// Built-in or custom smart playlist definition.
struct SmartPlaylistDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let systemImage: String
    let rules: [SmartPlaylistRule]
    var limit: Int = 100

    var subtitle: String {
        switch id {
        case "recently-played": return "Played in the last two weeks"
        case "unplayed-favorites": return "Highly rated, not heard lately"
        case "five-star": return "Only your five-star tracks"
        case "downloaded": return "Everything available offline"
        case "this-year": return "Tracks from \(Calendar.current.component(.year, from: Date()))"
        default: return "\(rules.count) rule\(rules.count == 1 ? "" : "s")"
        }
    }
}

enum SmartPlaylistCatalog {
    static var builtIn: [SmartPlaylistDefinition] {
        let year = Calendar.current.component(.year, from: Date())
        return [
            SmartPlaylistDefinition(
                id: "recently-played",
                name: "Recently Played",
                systemImage: "clock.fill",
                rules: [.playedWithinDays(14)]),
            SmartPlaylistDefinition(
                id: "unplayed-favorites",
                name: "Unplayed Favorites",
                systemImage: "heart.fill",
                rules: [.minRating(4), .notPlayedWithinDays(30)]),
            SmartPlaylistDefinition(
                id: "five-star",
                name: "5★ Only",
                systemImage: "star.fill",
                rules: [.minRating(5)]),
            SmartPlaylistDefinition(
                id: "downloaded",
                name: "Downloaded",
                systemImage: "arrow.down.circle.fill",
                rules: [.downloadedOnly]),
            SmartPlaylistDefinition(
                id: "this-year",
                name: "This Year",
                systemImage: "calendar",
                rules: [.yearAtLeast(year)]),
        ]
    }
}

/// Evaluates rule-based smart playlists against local ratings, play history, and downloads.
@MainActor
enum SmartPlaylistEngine {
    static func evaluate(
        definition: SmartPlaylistDefinition,
        userKey: String,
        database: AppDatabase,
        downloads: DownloadManager
    ) -> [Song] {
        let ratings = (try? database.allSongRatings(userKey: userKey)) ?? [:]
        let history = (try? database.playHistorySongs(userKey: userKey, limit: 2000)) ?? []
        let lastPlayed: [String: TimeInterval] = Dictionary(
            uniqueKeysWithValues: history.map { ($0.song.id, $0.playedAt) })
        let downloadedIDs = downloads.downloadedIDs
        let downloadedSongs = downloads.downloadedSongs()
        let ratedSongs = (try? database.ratedSongs(userKey: userKey, minRating: 1, limit: 2000)) ?? []

        var poolByID: [String: Song] = [:]
        for song in ratedSongs {
            var copy = song
            if let r = ratings[song.id] { copy.userRating = r }
            poolByID[song.id] = copy
        }
        for entry in history {
            var copy = entry.song
            if let r = ratings[copy.id] {
                copy.userRating = r
            } else if copy.userRating == nil {
                copy.userRating = poolByID[copy.id]?.userRating
            }
            // Prefer the richer rated snapshot when both exist.
            if poolByID[copy.id] == nil {
                poolByID[copy.id] = copy
            }
        }
        for song in downloadedSongs {
            var copy = song
            if let r = ratings[song.id] {
                copy.userRating = r
            } else if copy.userRating == nil {
                copy.userRating = poolByID[copy.id]?.userRating
            }
            if poolByID[copy.id] == nil {
                poolByID[copy.id] = copy
            }
        }

        let now = Date().timeIntervalSince1970
        let day: TimeInterval = 86_400

        let matched = poolByID.values.filter { song in
            definition.rules.allSatisfy { rule in
                matches(
                    song: song,
                    rule: rule,
                    lastPlayed: lastPlayed,
                    downloadedIDs: downloadedIDs,
                    now: now,
                    day: day)
            }
        }

        let sorted = sort(matched, definition: definition, lastPlayed: lastPlayed)
        return Array(sorted.prefix(max(1, definition.limit)))
    }

    private static func matches(
        song: Song,
        rule: SmartPlaylistRule,
        lastPlayed: [String: TimeInterval],
        downloadedIDs: Set<String>,
        now: TimeInterval,
        day: TimeInterval
    ) -> Bool {
        switch rule {
        case .minRating(let min):
            return (song.userRating ?? 0) >= min
        case .maxRating(let max):
            return (song.userRating ?? 0) <= max
        case .starred(let want):
            let isStarred = song.starred != nil
            return isStarred == want
        case .genreContains(let needle):
            guard let genre = song.genre, !needle.isEmpty else { return false }
            return genre.localizedCaseInsensitiveContains(needle)
        case .playedWithinDays(let days):
            guard let playedAt = lastPlayed[song.id] else { return false }
            return playedAt >= now - TimeInterval(days) * day
        case .notPlayedWithinDays(let days):
            // Never in local history, or last play older than the window.
            guard let playedAt = lastPlayed[song.id] else { return true }
            return playedAt < now - TimeInterval(days) * day
        case .yearAtLeast(let year):
            guard let y = song.year else { return false }
            return y >= year
        case .yearAtMost(let year):
            guard let y = song.year else { return false }
            return y <= year
        case .downloadedOnly:
            return downloadedIDs.contains(song.id)
        }
    }

    private static func sort(
        _ songs: [Song],
        definition: SmartPlaylistDefinition,
        lastPlayed: [String: TimeInterval]
    ) -> [Song] {
        let prefersRecency = definition.rules.contains {
            if case .playedWithinDays = $0 { return true }
            return false
        }
        let prefersRating = definition.rules.contains {
            if case .minRating = $0 { return true }
            if case .maxRating = $0 { return true }
            return false
        }

        if prefersRecency {
            return songs.sorted {
                let a = lastPlayed[$0.id] ?? 0
                let b = lastPlayed[$1.id] ?? 0
                if a != b { return a > b }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
        if prefersRating {
            return songs.sorted {
                let r0 = $0.userRating ?? 0
                let r1 = $1.userRating ?? 0
                if r0 != r1 { return r0 > r1 }
                let a = lastPlayed[$0.id] ?? 0
                let b = lastPlayed[$1.id] ?? 0
                if a != b { return a > b }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
        return songs.shuffled()
    }
}
