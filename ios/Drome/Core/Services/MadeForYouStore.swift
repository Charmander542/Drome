import Foundation

/// On-device Made for you shelf — daypart, vibes, genre mixes, Nonstop, fresh finds.
///
/// Built from Navidrome genre pulls + `VibeEngine` (same stack as Vibe Tuner),
/// with genre / Nonstop builders adapted from Aura’s `MixGenerator` (GPL-3.0).
/// Cached per account; rotated so the next rebuild prefers tracks that were
/// not on the last two shelves.
@MainActor
enum MadeForYouStore {
    private static let maxCards = 10
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

        if MadeForYouPreferences.genreMixesEnabled, built.count < maxCards {
            let genres = await topGenreNames(session: session)
            for genre in genres {
                guard built.count < maxCards else { break }
                let songs = await buildGenre(
                    genre,
                    session: session,
                    length: length,
                    used: used,
                    served: served)
                append(
                    id: "mfy.genre.\(genre.lowercased())",
                    title: "\(genre) Mix",
                    subtitle: "Your \(genre.lowercased()) favorites",
                    colors: genreColors(genre),
                    songs: songs)
            }
        }

        if MadeForYouPreferences.nonstopEnabled, built.count < maxCards {
            let songs = await buildNonstop(
                session: session,
                length: max(length, 50),
                used: used,
                served: served)
            append(
                id: "mfy.nonstop",
                title: "Nonstop",
                subtitle: "What you like, and more around it — without end",
                colors: ["#2A9D8F", "#0B132B"],
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

    private static func buildGenre(
        _ genre: String,
        session: AppSession,
        length: Int,
        used: Set<String>,
        served: Set<String>
    ) async -> [Song] {
        let client = session.client
        let count = max(60, length + 10)
        let total = await genreSongCount(genre, session: session)
        let offset = Self.randomOffset(in: total, taking: count)
        var pool = (try? await client.songsByGenre(genre, count: count, offset: offset)) ?? []
        pool = applyGenreExclusions(pool)
        return rested(pool, used: used, served: served, length: length)
    }

    /// Liked + nearby + unheard — seed for Infinite Shuffle / Nonstop.
    private static func buildNonstop(
        session: AppSession,
        length: Int,
        used: Set<String>,
        served: Set<String>
    ) async -> [Song] {
        let client = session.client
        var pool: [Song] = []

        if let starred = try? await client.starred() {
            pool += starred.song ?? []
        }

        let topArtists = session.ratings.memory.topPlayedArtists(limit: 4)
        await withTaskGroup(of: [Song].self) { group in
            for name in topArtists {
                group.addTask {
                    if let match = try? await client.search(name, artistCount: 1, albumCount: 0, songCount: 0),
                       let artist = match.artists.first {
                        return (try? await client.similarSongs(artistId: artist.id, count: 25)) ?? []
                    }
                    return (try? await client.topSongs(artistName: name, count: 15)) ?? []
                }
            }
            for await batch in group { pool += batch }
        }

        if pool.count < length {
            pool += (try? await client.randomSongs(size: 80)) ?? []
        }

        pool = applyGenreExclusions(pool)
        // Prefer unserved / unused first so Nonstop feels fresh each rebuild.
        return rested(pool, used: used, served: served, length: length)
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

    /// Prefer songs the last two shelves didn't serve; fill from the rest.
    private static func rested(
        _ songs: [Song],
        used: Set<String>,
        served: Set<String>,
        length: Int
    ) -> [Song] {
        var seen = Set<String>()
        var fresh: [Song] = []
        var recycle: [Song] = []
        for song in songs.shuffled() {
            guard seen.insert(song.id).inserted else { continue }
            if used.contains(song.id) { continue }
            if !allowsGenre(song) { continue }
            if served.contains(song.id) {
                recycle.append(song)
            } else {
                fresh.append(song)
            }
            if fresh.count >= length { return Array(fresh.prefix(length)) }
        }
        return Array((fresh + recycle).prefix(length))
    }

    private static func topGenreNames(session: AppSession) async -> [String] {
        let picked = MadeForYouPreferences.preferredGenres
        let excluded = MadeForYouPreferences.excludedGenres
        if !picked.isEmpty {
            return Array(picked.filter { !excluded.contains($0.lowercased()) }.prefix(4))
        }

        // From recent play weights in ListenerMemory via top artists' songs —
        // fall back to the library's biggest genres.
        var counts: [String: Int] = [:]
        let history = (try? session.database.playHistorySongs(
            userKey: session.account.userKey, limit: 200)) ?? []
        for entry in history {
            guard let raw = entry.song.genre, !raw.isEmpty else { continue }
            let name = GenreNormalizer.shared.normalize(raw) ?? raw
            guard !excluded.contains(name.lowercased()) else { continue }
            counts[name, default: 0] += 1
        }
        let fromListening = counts.sorted { $0.value > $1.value }.map(\.key)
        if !fromListening.isEmpty {
            return Array(fromListening.prefix(4))
        }

        let all = (try? await session.client.genres()) ?? []
        return all
            .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
            .map(\.value)
            .filter { !excluded.contains($0.lowercased()) && !$0.isEmpty }
            .prefix(4)
            .map { $0 }
    }

    private static func genreSongCount(_ genre: String, session: AppSession) async -> Int {
        let all = (try? await session.client.genres()) ?? []
        return all.first { $0.value.caseInsensitiveCompare(genre) == .orderedSame }?.songCount ?? 0
    }

    /// Somewhere in the genre, not always at its start (Aura MixGenerator).
    private static func randomOffset(in total: Int, taking count: Int) -> Int {
        guard total > count else { return 0 }
        return Int.random(in: 0...(total - count))
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

    private static func genreColors(_ genre: String) -> [String] {
        var h = 5381
        for b in genre.lowercased().utf8 { h = ((h &* 33) &+ Int(b)) & 0x7fffffff }
        let hue = Double(h % 360) / 360.0
        // Approximate hex from hue for the DailyMix color list (templated cover wins).
        let top = String(format: "#%02X%02X%02X",
                         Int(max(0, min(1, hueToRGB(hue, 0.70, 0.78).0)) * 255),
                         Int(max(0, min(1, hueToRGB(hue, 0.70, 0.78).1)) * 255),
                         Int(max(0, min(1, hueToRGB(hue, 0.70, 0.78).2)) * 255))
        let bot = String(format: "#%02X%02X%02X",
                         Int(max(0, min(1, hueToRGB(hue + 0.09, 0.82, 0.42).0)) * 255),
                         Int(max(0, min(1, hueToRGB(hue + 0.09, 0.82, 0.42).1)) * 255),
                         Int(max(0, min(1, hueToRGB(hue + 0.09, 0.82, 0.42).2)) * 255))
        return [top, bot]
    }

    private static func hueToRGB(_ h: Double, _ s: Double, _ b: Double) -> (Double, Double, Double) {
        let hue = h.truncatingRemainder(dividingBy: 1)
        // Simple HSB → RGB.
        let c = b * s
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c
        let rgb: (Double, Double, Double)
        switch Int(hue * 6) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
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
