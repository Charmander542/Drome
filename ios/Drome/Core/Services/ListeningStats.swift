import Foundation

enum ListeningStatsPeriod: String, CaseIterable, Identifiable, Hashable {
    case days7
    case days30
    case thisYear
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .thisYear: return "\(Calendar.current.component(.year, from: Date()))"
        case .allTime: return "All time"
        }
    }

    /// Calendar-year label for Wrapped covers ("2026").
    var wrappedLabel: String {
        switch self {
        case .thisYear:
            return "\(Calendar.current.component(.year, from: Date()))"
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .allTime: return "All time"
        }
    }

    /// Absolute cutoff, or `nil` for all retained history.
    func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .days7:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .days30:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .thisYear:
            let year = calendar.component(.year, from: now)
            return calendar.date(from: DateComponents(year: year, month: 1, day: 1))
        case .allTime:
            return nil
        }
    }

    /// Kept for callers that still expect day-based lookback (`nil` = unbounded / year).
    var lookbackDays: Int? {
        switch self {
        case .days7: return 7
        case .days30: return 30
        case .thisYear, .allTime: return nil
        }
    }
}

struct ListeningStats {
    struct RankedItem: Identifiable, Hashable {
        let id: String
        let name: String
        let subtitle: String?
        let playCount: Int
        let coverArt: String?
    }

    struct RankedSong: Identifiable, Hashable {
        let id: String
        let song: Song
        let playCount: Int
    }

    struct RankedGenre: Identifiable, Hashable {
        let id: String
        let name: String
        let playCount: Int
    }

    let totalPlays: Int
    let totalSeconds: Int
    let activeDays: Int
    let uniqueSongs: Int
    let uniqueArtists: Int
    let topArtists: [RankedItem]
    let topAlbums: [RankedItem]
    let topSongs: [RankedSong]
    let topGenres: [RankedGenre]
    let period: ListeningStatsPeriod?

    var hoursListened: Double {
        Double(totalSeconds) / 3600.0
    }

    var isEmpty: Bool { totalPlays == 0 }

    /// One-line personality for Year Wrapped hero.
    var personality: String {
        if let top = topGenres.first {
            return "Mostly \(top.name.lowercased()) this stretch"
        }
        if let artist = topArtists.first {
            return "Heavy on \(artist.name)"
        }
        return "Your year in music"
    }

    static let empty = ListeningStats(
        totalPlays: 0,
        totalSeconds: 0,
        activeDays: 0,
        uniqueSongs: 0,
        uniqueArtists: 0,
        topArtists: [],
        topAlbums: [],
        topSongs: [],
        topGenres: [],
        period: nil
    )

    /// Aggregates decoded play rows. Prefer `Song.duration` from JSON; missing duration counts as 0.
    static func aggregate(
        plays: [(playedAt: TimeInterval, song: Song)],
        topLimit: Int = 5,
        period: ListeningStatsPeriod? = nil,
        calendar: Calendar = .current
    ) -> ListeningStats {
        guard !plays.isEmpty else {
            return ListeningStats(
                totalPlays: 0,
                totalSeconds: 0,
                activeDays: 0,
                uniqueSongs: 0,
                uniqueArtists: 0,
                topArtists: [],
                topAlbums: [],
                topSongs: [],
                topGenres: [],
                period: period)
        }

        var totalSeconds = 0
        var dayKeys = Set<String>()
        var artistCounts: [String: (name: String, count: Int, cover: String?)] = [:]
        var albumCounts: [String: (name: String, artist: String?, count: Int, cover: String?)] = [:]
        var songCounts: [String: (song: Song, count: Int)] = [:]
        var genreCounts: [String: Int] = [:]

        for play in plays {
            let song = play.song
            totalSeconds += max(0, song.duration ?? 0)

            let day = calendar.dateComponents(
                [.year, .month, .day],
                from: Date(timeIntervalSince1970: play.playedAt)
            )
            if let y = day.year, let m = day.month, let d = day.day {
                dayKeys.insert("\(y)-\(m)-\(d)")
            }

            let artistName = song.displayArtist.isEmpty
                ? (song.artist?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Unknown Artist")
                : song.displayArtist
            let artistKey = (song.artistId?.nilIfEmpty) ?? artistName.lowercased()
            var artist = artistCounts[artistKey] ?? (name: artistName, count: 0, cover: song.coverArt)
            artist.count += 1
            if artist.cover == nil { artist.cover = song.coverArt }
            artistCounts[artistKey] = artist

            let albumName = song.album?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Unknown Album"
            let albumKey = (song.albumId?.nilIfEmpty) ?? "\(albumName.lowercased())|\(artistName.lowercased())"
            var album = albumCounts[albumKey] ?? (name: albumName, artist: artistName, count: 0, cover: song.coverArt)
            album.count += 1
            if album.cover == nil { album.cover = song.coverArt }
            if album.artist == nil { album.artist = artistName }
            albumCounts[albumKey] = album

            var songEntry = songCounts[song.id] ?? (song: song, count: 0)
            songEntry.count += 1
            if (songEntry.song.coverArt == nil && song.coverArt != nil)
                || (songEntry.song.duration == nil && song.duration != nil) {
                songEntry.song = song
            }
            songCounts[song.id] = songEntry

            if let raw = song.genre, !raw.isEmpty {
                let name = GenreNormalizer.shared.normalize(raw) ?? raw
                genreCounts[name, default: 0] += 1
            }
        }

        let topArtists = artistCounts
            .map { RankedItem(id: $0.key, name: $0.value.name, subtitle: nil, playCount: $0.value.count, coverArt: $0.value.cover) }
            .sorted(by: Self.rankSort)
            .prefix(topLimit)
            .map { $0 }

        let topAlbums = albumCounts
            .map { RankedItem(id: $0.key, name: $0.value.name, subtitle: $0.value.artist, playCount: $0.value.count, coverArt: $0.value.cover) }
            .sorted(by: Self.rankSort)
            .prefix(topLimit)
            .map { $0 }

        let topSongs = songCounts
            .map { RankedSong(id: $0.key, song: $0.value.song, playCount: $0.value.count) }
            .sorted {
                if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
                return $0.song.title.localizedCaseInsensitiveCompare($1.song.title) == .orderedAscending
            }
            .prefix(topLimit)
            .map { $0 }

        let topGenres = genreCounts
            .map { RankedGenre(id: $0.key.lowercased(), name: $0.key, playCount: $0.value) }
            .sorted {
                if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .prefix(topLimit)
            .map { $0 }

        return ListeningStats(
            totalPlays: plays.count,
            totalSeconds: totalSeconds,
            activeDays: dayKeys.count,
            uniqueSongs: songCounts.count,
            uniqueArtists: artistCounts.count,
            topArtists: topArtists,
            topAlbums: topAlbums,
            topSongs: topSongs,
            topGenres: topGenres,
            period: period
        )
    }

    private static func rankSort(_ a: RankedItem, _ b: RankedItem) -> Bool {
        if a.playCount != b.playCount { return a.playCount > b.playCount }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
