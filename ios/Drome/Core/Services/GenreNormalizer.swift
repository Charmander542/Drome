import Foundation

/// A curated top-level genre with the raw server tags that map into it.
struct NormalizedGenre: Identifiable, Hashable {
    var id: String { displayName }
    let displayName: String
    let rawTags: [String]
    let songCount: Int
    let albumCount: Int
}

/// Maps messy library genre tags onto a small curated set, merging counts
/// and supporting user overrides via `UserDefaults`.
final class GenreNormalizer {
    static let shared = GenreNormalizer()

    static let overridesKey = "drome.genreAliases"

    /// Curated display names shown in the library.
    static let topLevel: [String] = [
        "Rock", "Pop", "Hip-Hop", "R&B", "Electronic", "Dance", "Jazz",
        "Classical", "Metal", "Punk", "Folk", "Country", "Indie", "Alternative",
        "Soul", "Funk", "Blues", "Reggae", "Latin", "Soundtrack", "World",
        "Ambient", "Experimental",
    ]

    private let topLevelByKey: [String: String]
    private let defaultAliases: [String: String]

    init() {
        var byKey: [String: String] = [:]
        for name in Self.topLevel {
            byKey[Self.canonicalKey(name)] = name
        }
        self.topLevelByKey = byKey
        self.defaultAliases = Self.buildDefaultAliases(topLevelByKey: byKey)
    }

    /// Returns the curated display name for `raw`, or `nil` if empty / unmappable.
    func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = Self.canonicalKey(trimmed)
        let aliases = mergedAliases()

        if let mapped = aliases[key] { return mapped }
        if let exact = topLevelByKey[key] { return exact }
        return nil
    }

    /// Groups server genres under curated names, summing counts and collecting raw tags.
    /// Groups with no songs and no albums are omitted.
    func group(_ genres: [Genre]) -> [(name: String, rawValues: [String], songCount: Int, albumCount: Int)] {
        var buckets: [String: (raw: [String], songs: Int, albums: Int)] = [:]

        for genre in genres {
            guard let name = normalize(genre.value) else { continue }
            var entry = buckets[name] ?? (raw: [], songs: 0, albums: 0)
            if !entry.raw.contains(genre.value) {
                entry.raw.append(genre.value)
            }
            entry.songs += genre.songCount ?? 0
            entry.albums += genre.albumCount ?? 0
            buckets[name] = entry
        }

        return buckets
            .map { (name: $0.key, rawValues: $0.value.raw.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }, songCount: $0.value.songs, albumCount: $0.value.albums) }
            .filter { $0.songCount > 0 || $0.albumCount > 0 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func groupedGenres(_ genres: [Genre]) -> [NormalizedGenre] {
        group(genres).map {
            NormalizedGenre(
                displayName: $0.name,
                rawTags: $0.rawValues,
                songCount: $0.songCount,
                albumCount: $0.albumCount
            )
        }
    }

    // MARK: - Overrides

    private func mergedAliases() -> [String: String] {
        var map = defaultAliases
        if let custom = UserDefaults.standard.dictionary(forKey: Self.overridesKey) as? [String: String] {
            for (rawKey, rawValue) in custom {
                let key = Self.canonicalKey(rawKey)
                guard !key.isEmpty else { continue }
                // Prefer mapping onto a known top-level name when possible.
                if let canonical = topLevelByKey[Self.canonicalKey(rawValue)] {
                    map[key] = canonical
                } else if !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    map[key] = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return map
    }

    /// Lowercased key with punctuation folded so "Hip-Hop", "hip hop", "Hip/Hop" match.
    static func canonicalKey(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var scaled = ""
        scaled.reserveCapacity(lowered.count)
        var pendingSpace = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                if pendingSpace, !scaled.isEmpty { scaled.append(" ") }
                pendingSpace = false
                scaled.append(ch)
            } else if ch == "&" {
                if pendingSpace, !scaled.isEmpty { scaled.append(" ") }
                pendingSpace = false
                if !scaled.isEmpty { scaled.append(" ") }
                scaled.append("and")
                pendingSpace = true
            } else {
                pendingSpace = true
            }
        }
        return scaled.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Default alias table

    private static func buildDefaultAliases(topLevelByKey: [String: String]) -> [String: String] {
        // Values are curated display names from `topLevel`.
        let pairs: [(String, String)] = [
            // Hip-Hop
            ("hip hop", "Hip-Hop"),
            ("hip-hop", "Hip-Hop"),
            ("hiphop", "Hip-Hop"),
            ("hip hop/rap", "Hip-Hop"),
            ("hip-hop/rap", "Hip-Hop"),
            ("rap", "Hip-Hop"),
            ("rap hop", "Hip-Hop"),
            ("gangsta rap", "Hip-Hop"),
            ("trap", "Hip-Hop"),
            ("boom bap", "Hip-Hop"),
            ("underground hip hop", "Hip-Hop"),
            ("conscious hip hop", "Hip-Hop"),
            ("east coast hip hop", "Hip-Hop"),
            ("west coast hip hop", "Hip-Hop"),
            ("southern hip hop", "Hip-Hop"),
            ("alt hip hop", "Hip-Hop"),
            ("alternative hip hop", "Hip-Hop"),

            // R&B
            ("r&b", "R&B"),
            ("r and b", "R&B"),
            ("rnb", "R&B"),
            ("rhythm and blues", "R&B"),
            ("rhythm & blues", "R&B"),
            ("contemporary r&b", "R&B"),
            ("contemporary r and b", "R&B"),
            ("neo soul", "R&B"),
            ("neosoul", "R&B"),

            // Electronic
            ("edm", "Electronic"),
            ("electronica", "Electronic"),
            ("electronic music", "Electronic"),
            ("idm", "Electronic"),
            ("intelligent dance music", "Electronic"),
            ("downtempo", "Electronic"),
            ("synthwave", "Electronic"),
            ("synth pop", "Electronic"),
            ("synthpop", "Electronic"),
            ("electro", "Electronic"),
            ("electroclash", "Electronic"),
            ("breakbeat", "Electronic"),
            ("glitch", "Electronic"),
            ("industrial", "Electronic"),
            ("leftfield", "Electronic"),

            // Dance
            ("house", "Dance"),
            ("deep house", "Dance"),
            ("tech house", "Dance"),
            ("progressive house", "Dance"),
            ("techno", "Dance"),
            ("trance", "Dance"),
            ("progressive trance", "Dance"),
            ("psytrance", "Dance"),
            ("disco", "Dance"),
            ("nu disco", "Dance"),
            ("drum and bass", "Dance"),
            ("drum & bass", "Dance"),
            ("dnb", "Dance"),
            ("d&b", "Dance"),
            ("dubstep", "Dance"),
            ("garage", "Dance"),
            ("uk garage", "Dance"),
            ("hardcore", "Dance"),
            ("happy hardcore", "Dance"),
            ("dance pop", "Dance"),
            ("club", "Dance"),
            ("eurodance", "Dance"),

            // Rock
            ("classic rock", "Rock"),
            ("hard rock", "Rock"),
            ("soft rock", "Rock"),
            ("progressive rock", "Rock"),
            ("prog rock", "Rock"),
            ("prog", "Rock"),
            ("psychedelic rock", "Rock"),
            ("psych rock", "Rock"),
            ("blues rock", "Rock"),
            ("garage rock", "Rock"),
            ("southern rock", "Rock"),
            ("arena rock", "Rock"),
            ("art rock", "Rock"),
            ("grunge", "Rock"),
            ("post rock", "Rock"),
            ("post-rock", "Rock"),
            ("math rock", "Rock"),
            ("stoner rock", "Rock"),
            ("rock and roll", "Rock"),
            ("rock & roll", "Rock"),
            ("rock n roll", "Rock"),

            // Alternative / Indie
            ("alt rock", "Alternative"),
            ("alternative rock", "Alternative"),
            ("alt", "Alternative"),
            ("adult alternative", "Alternative"),
            ("indie rock", "Indie"),
            ("indie pop", "Indie"),
            ("indie folk", "Indie"),
            ("indietronica", "Indie"),
            ("lo-fi", "Indie"),
            ("lofi", "Indie"),
            ("dream pop", "Indie"),
            ("shoegaze", "Alternative"),
            ("britpop", "Alternative"),
            ("new wave", "Alternative"),
            ("post punk", "Alternative"),
            ("post-punk", "Alternative"),

            // Metal
            ("heavy metal", "Metal"),
            ("death metal", "Metal"),
            ("black metal", "Metal"),
            ("thrash metal", "Metal"),
            ("thrash", "Metal"),
            ("doom metal", "Metal"),
            ("doom", "Metal"),
            ("power metal", "Metal"),
            ("progressive metal", "Metal"),
            ("prog metal", "Metal"),
            ("metalcore", "Metal"),
            ("deathcore", "Metal"),
            ("nu metal", "Metal"),
            ("nu-metal", "Metal"),
            ("symphonic metal", "Metal"),
            ("folk metal", "Metal"),
            ("groove metal", "Metal"),
            ("speed metal", "Metal"),

            // Punk
            ("punk rock", "Punk"),
            ("pop punk", "Punk"),
            ("pop-punk", "Punk"),
            ("hardcore punk", "Punk"),
            ("skate punk", "Punk"),
            ("oi", "Punk"),
            ("crust punk", "Punk"),
            ("emo", "Punk"),
            ("screamo", "Punk"),

            // Pop
            ("pop rock", "Pop"),
            ("teen pop", "Pop"),
            ("art pop", "Pop"),
            ("chamber pop", "Pop"),
            ("electropop", "Pop"),
            ("k-pop", "Pop"),
            ("kpop", "Pop"),
            ("j-pop", "Pop"),
            ("jpop", "Pop"),
            ("dance-pop", "Pop"),
            ("adult contemporary", "Pop"),
            ("power pop", "Pop"),

            // Jazz
            ("smooth jazz", "Jazz"),
            ("bebop", "Jazz"),
            ("be-bop", "Jazz"),
            ("hard bop", "Jazz"),
            ("free jazz", "Jazz"),
            ("fusion", "Jazz"),
            ("jazz fusion", "Jazz"),
            ("contemporary jazz", "Jazz"),
            ("vocal jazz", "Jazz"),
            ("cool jazz", "Jazz"),
            ("latin jazz", "Jazz"),
            ("acid jazz", "Jazz"),

            // Classical
            ("orchestral", "Classical"),
            ("opera", "Classical"),
            ("chamber music", "Classical"),
            ("baroque", "Classical"),
            ("romantic", "Classical"),
            ("contemporary classical", "Classical"),
            ("modern classical", "Classical"),
            ("symphony", "Classical"),
            ("choral", "Classical"),

            // Folk / Country
            ("folk rock", "Folk"),
            ("traditional folk", "Folk"),
            ("singer-songwriter", "Folk"),
            ("singer songwriter", "Folk"),
            ("americana", "Folk"),
            ("bluegrass", "Country"),
            ("alt country", "Country"),
            ("alternative country", "Country"),
            ("country rock", "Country"),
            ("outlaw country", "Country"),
            ("contemporary country", "Country"),
            ("honky tonk", "Country"),
            ("nashville", "Country"),

            // Soul / Funk / Blues
            ("motown", "Soul"),
            ("southern soul", "Soul"),
            ("northern soul", "Soul"),
            ("funk rock", "Funk"),
            ("p-funk", "Funk"),
            ("boogie", "Funk"),
            ("delta blues", "Blues"),
            ("chicago blues", "Blues"),
            ("electric blues", "Blues"),
            ("acoustic blues", "Blues"),
            ("rhythm blues", "Blues"),

            // Reggae / Latin / World
            ("dancehall", "Reggae"),
            ("ska", "Reggae"),
            ("dub", "Reggae"),
            ("roots reggae", "Reggae"),
            ("reggaeton", "Latin"),
            ("salsa", "Latin"),
            ("mambo", "Latin"),
            ("merengue", "Latin"),
            ("bachata", "Latin"),
            ("cumbia", "Latin"),
            ("bossa nova", "Latin"),
            ("samba", "Latin"),
            ("mpb", "Latin"),
            ("latin pop", "Latin"),
            ("latin rock", "Latin"),
            ("tango", "Latin"),
            ("flamenco", "Latin"),
            ("afrobeat", "World"),
            ("afropop", "World"),
            ("world music", "World"),
            ("worldbeat", "World"),
            ("celtic", "World"),
            ("african", "World"),
            ("middle eastern", "World"),
            ("indian classical", "World"),
            ("bollywood", "World"),

            // Soundtrack / Ambient / Experimental
            ("ost", "Soundtrack"),
            ("original soundtrack", "Soundtrack"),
            ("film score", "Soundtrack"),
            ("film music", "Soundtrack"),
            ("score", "Soundtrack"),
            ("musical", "Soundtrack"),
            ("video game", "Soundtrack"),
            ("videogame", "Soundtrack"),
            ("game music", "Soundtrack"),
            ("dark ambient", "Ambient"),
            ("drone", "Ambient"),
            ("new age", "Ambient"),
            ("chillout", "Ambient"),
            ("chill out", "Ambient"),
            ("chillwave", "Ambient"),
            ("avant-garde", "Experimental"),
            ("avant garde", "Experimental"),
            ("noise", "Experimental"),
            ("experimental electronic", "Experimental"),
            ("musique concrete", "Experimental"),
        ]

        var map: [String: String] = [:]
        // Ensure every top-level name resolves to itself via key.
        for (key, name) in topLevelByKey {
            map[key] = name
        }
        for (alias, target) in pairs {
            map[canonicalKey(alias)] = target
        }
        return map
    }
}
