import Foundation

/// On-device Made for you shelf — daypart, vibe cards, and fresh finds.
///
/// Built from Navidrome genre pulls + `VibeEngine` (same stack as Vibe Tuner),
/// cached per account, and rotated so the next rebuild prefers tracks that
/// were not on the last two shelves.
@MainActor
enum MadeForYouStore {
    private static let maxCards = 7
    private static let minSongs = 8
    private static let staleAfter: TimeInterval = 8 * 3600

    // MARK: - Daypart

    enum Daypart: String, CaseIterable {
        case morning, afternoon, evening, night

        static var current: Daypart {
            switch Calendar.current.component(.hour, from: Date()) {
            case 5..<12: return .morning
            case 12..<17: return .afternoon
            case 17..<22: return .evening
            default: return .night
            }
        }

        var title: String {
            switch self {
            case .morning: return "Morning Mix"
            case .afternoon: return "Afternoon Mix"
            case .evening: return "Evening Mix"
            case .night: return "Late Night Mix"
            }
        }

        var subtitle: String {
            switch self {
            case .morning: return "Ease into the day"
            case .afternoon: return "Keep the afternoon moving"
            case .evening: return "Settle in for the evening"
            case .night: return "Quiet hours"
            }
        }

        /// Closest Vibe Tuner station for this part of the day.
        var vibe: MoodVibe {
            switch self {
            case .morning: return .feelGood
            case .afternoon: return .hype
            case .evening: return .chill
            case .night: return .lateNight
            }
        }

        var colors: [String] {
            switch self {
            case .morning: return ["#F4A261", "#9B2226"]
            case .afternoon: return ["#E76F51", "#6D2E4B"]
            case .evening: return ["#7B61FF", "#1B1340"]
            case .night: return ["#1D3557", "#0B132B"]
            }
        }
    }

    // MARK: - Public

    static func cached(userKey: String) -> [DailyMix] {
        guard let data = UserDefaults.standard.data(forKey: contentsKey(userKey)),
              let mixes = try? JSONDecoder().decode([DailyMix].self, from: data)
        else { return [] }
        return mixes
    }

    static func generatedAt(userKey: String) -> Date? {
        UserDefaults.standard.object(forKey: dateKey(userKey)) as? Date
    }

    /// Cheap no-op when the shelf is still fresh for this daypart.
    static func refreshIfNeeded(session: AppSession) async -> [DailyMix] {
        let userKey = session.account.userKey
        let mixes = cached(userKey: userKey)
        let bucket = Daypart.current.rawValue
        if needsRegeneration(userKey: userKey, hasMixes: !mixes.isEmpty, bucket: bucket) {
            return await regenerate(session: session)
        }
        return mixes
    }

    static func regenerate(session: AppSession) async -> [DailyMix] {
        guard MadeForYouPreferences.anyShelfEnabled else {
            clear(userKey: session.account.userKey)
            return []
        }

        let userKey = session.account.userKey
        let length = MadeForYouPreferences.length
        let daypart = Daypart.current
        let served = servedIDs(userKey: userKey)
        var used = Set<String>()
        var built: [DailyMix] = []
        var index = 0

        func append(id: String, title: String, subtitle: String, colors: [String], songs: [Song]) {
            guard songs.count >= minSongs, built.count < maxCards else { return }
            let covers = coverIDs(from: songs)
            built.append(DailyMix(
                id: id,
                index: index,
                title: title,
                subtitle: subtitle,
                colors: colors,
                coverArtIds: covers,
                songs: songs))
            used.formUnion(songs.map(\.id))
            index += 1
        }

        if MadeForYouPreferences.daypartEnabled {
            let songs = await buildVibe(
                daypart.vibe,
                session: session,
                length: length,
                used: used,
                served: served)
            append(
                id: "mfy.daypart.\(daypart.rawValue)",
                title: daypart.title,
                subtitle: daypart.subtitle,
                colors: daypart.colors,
                songs: songs)
        }

        let daypartVibe = MadeForYouPreferences.daypartEnabled ? daypart.vibe : nil
        for vibe in MadeForYouPreferences.shelfVibes
        where MadeForYouPreferences.vibeEnabled(vibe) && vibe != daypartVibe {
            let songs = await buildVibe(
                vibe,
                session: session,
                length: length,
                used: used,
                served: served)
            append(
                id: "mfy.vibe.\(vibe.rawValue)",
                title: "\(vibe.title) Mix",
                subtitle: vibe.blurb,
                colors: vibeColors(vibe),
                songs: songs)
        }

        if MadeForYouPreferences.discoveryEnabled, built.count < maxCards {
            let songs = await buildDiscovery(
                session: session,
                length: length,
                used: used,
                served: served)
            append(
                id: "mfy.discovery",
                title: "Fresh Finds",
                subtitle: "Near what you play — not the same tracks again",
                colors: ["#2A9D8F", "#1D3557"],
                songs: songs)
        }

        if built.isEmpty {
            // Keep the last shelf if the library was quiet this pass.
            let previous = cached(userKey: userKey)
            if !previous.isEmpty { return previous }
            return []
        }

        save(built, userKey: userKey, bucket: daypart.rawValue)
        recordServed(built.flatMap { $0.songs.map(\.id) }, userKey: userKey)
        return built
    }

    // MARK: - Builders

    private static func buildVibe(
        _ vibe: MoodVibe,
        session: AppSession,
        length: Int,
        used: Set<String>,
        served: Set<String>
    ) async -> [Song] {
        let pool = await MoodPlayer.gatherPool(vibe: vibe, session: session)
        let filtered = applyGenreExclusions(pool)
        var excluded = session.rotation.excludedIDs
        excluded.formUnion(used)
        excluded.formUnion(served)

        var picked = VibeEngine.pick(
            vibe: vibe,
            from: filtered,
            excluded: excluded,
            memory: session.ratings.memory,
            count: length)
        if picked.count < minSongs {
            excluded = session.rotation.excludedIDs.union(used)
            picked = VibeEngine.pick(
                vibe: vibe,
                from: filtered,
                excluded: excluded,
                memory: session.ratings.memory,
                count: length)
        }
        return picked
    }

    private static func buildDiscovery(
        session: AppSession,
        length: Int,
        used: Set<String>,
        served: Set<String>
    ) async -> [Song] {
        let client = session.client
        let artists = session.ratings.memory.topPlayedArtists(limit: 5)
        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for name in artists {
                group.addTask {
                    // Prefer similar-to-artist when we can resolve an id from recent history.
                    if let match = try? await client.search(name, artistCount: 1, albumCount: 0, songCount: 0),
                       let artist = match.artists.first {
                        return (try? await client.similarSongs(artistId: artist.id, count: 30)) ?? []
                    }
                    return (try? await client.topSongs(artistName: name, count: 20)) ?? []
                }
            }
            for await batch in group {
                pool.append(contentsOf: batch)
            }
        }
        if pool.count < 20 {
            pool += (try? await client.randomSongs(size: 80)) ?? []
        }

        let known = used
            .union(served)
            .union(session.rotation.excludedIDs)
        var seen = Set<String>()
        var fresh: [Song] = []
        for song in pool.shuffled() {
            guard seen.insert(song.id).inserted, !known.contains(song.id) else { continue }
            if !allowsGenre(song) { continue }
            fresh.append(song)
            if fresh.count >= length { break }
        }
        return fresh
    }

    private static func applyGenreExclusions(_ songs: [Song]) -> [Song] {
        guard !MadeForYouPreferences.excludedGenres.isEmpty else { return songs }
        return songs.filter { allowsGenre($0) }
    }

    private static func allowsGenre(_ song: Song) -> Bool {
        let excluded = MadeForYouPreferences.excludedGenres
        guard !excluded.isEmpty else { return true }
        let raw = (song.genre ?? "").lowercased()
        guard !raw.isEmpty else { return true }
        if excluded.contains(raw) { return false }
        if let normalized = GenreNormalizer.shared.normalize(song.genre ?? ""),
           excluded.contains(normalized.lowercased()) {
            return false
        }
        let parts = raw.split(whereSeparator: { ";,/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return !parts.contains(where: excluded.contains)
    }

    private static func coverIDs(from songs: [Song], limit: Int = 4) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for song in songs {
            let id = song.coverArt ?? song.albumId ?? song.id
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(id)
            if out.count >= limit { break }
        }
        return out
    }

    private static func vibeColors(_ vibe: MoodVibe) -> [String] {
        switch vibe {
        case .focus: return ["#C4B896", "#1E1C16"]
        case .chill: return ["#40916C", "#081C15"]
        case .feelGood: return ["#F4A261", "#9B2226"]
        case .hype: return ["#E76F51", "#370617"]
        case .lateNight: return ["#6B8CFF", "#0B132B"]
        case .heartbreak: return ["#C9184A", "#370617"]
        case .lucky: return ["#2A9D8F", "#1D3557"]
        }
    }

    // MARK: - Cache

    private static func needsRegeneration(userKey: String, hasMixes: Bool, bucket: String) -> Bool {
        guard hasMixes,
              UserDefaults.standard.string(forKey: bucketKey(userKey)) == bucket,
              let last = generatedAt(userKey: userKey)
        else { return true }
        return Date().timeIntervalSince(last) > staleAfter
    }

    private static func save(_ mixes: [DailyMix], userKey: String, bucket: String) {
        if let data = try? JSONEncoder().encode(mixes) {
            UserDefaults.standard.set(data, forKey: contentsKey(userKey))
        }
        UserDefaults.standard.set(Date(), forKey: dateKey(userKey))
        UserDefaults.standard.set(bucket, forKey: bucketKey(userKey))
    }

    private static func clear(userKey: String) {
        UserDefaults.standard.removeObject(forKey: contentsKey(userKey))
        UserDefaults.standard.removeObject(forKey: dateKey(userKey))
        UserDefaults.standard.removeObject(forKey: bucketKey(userKey))
    }

    private static func servedIDs(userKey: String) -> Set<String> {
        let generations = UserDefaults.standard.array(forKey: servedKey(userKey)) as? [[String]] ?? []
        return Set(generations.joined())
    }

    private static func recordServed(_ ids: [String], userKey: String) {
        let generations = UserDefaults.standard.array(forKey: servedKey(userKey)) as? [[String]] ?? []
        UserDefaults.standard.set(Array((generations + [ids]).suffix(2)), forKey: servedKey(userKey))
    }

    private static func contentsKey(_ userKey: String) -> String { "drome.mfy.contents.\(userKey)" }
    private static func dateKey(_ userKey: String) -> String { "drome.mfy.date.\(userKey)" }
    private static func bucketKey(_ userKey: String) -> String { "drome.mfy.bucket.\(userKey)" }
    private static func servedKey(_ userKey: String) -> String { "drome.mfy.served.\(userKey)" }
}
