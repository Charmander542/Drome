import Foundation

/// Settings for the on-device Made for you shelf (Home).
///
/// Defaults keep a tight rail: daypart + a few vibes + fresh finds + Nonstop.
/// Genre mixes and companion Daily Mixes stay optional / separate.
enum MadeForYouPreferences {
    private static let prefix = "drome.mfy."

    static let daypartKey = prefix + "daypart"
    static let discoveryKey = prefix + "discovery"
    static let genreMixesKey = prefix + "genreMixes"
    static let nonstopKey = prefix + "nonstop"
    static let lengthKey = prefix + "length"
    static let excludedGenresKey = prefix + "excludedGenres"
    static let preferredGenresKey = prefix + "preferredGenres"

    private static func vibeKey(_ vibe: MoodVibe) -> String {
        prefix + "vibe." + vibe.rawValue
    }

    /// Vibes that can appear as Made for you cards (Lucky stays tuner-only).
    static let shelfVibes: [MoodVibe] = [
        .focus, .chill, .feelGood, .hype, .lateNight, .heartbreak
    ]

    private static func flag(_ key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    static var daypartEnabled: Bool {
        get { flag(daypartKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: daypartKey) }
    }

    static var discoveryEnabled: Bool {
        get { flag(discoveryKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: discoveryKey) }
    }

    /// One mix per top listened / picked genre (Aura-style genre shelf).
    static var genreMixesEnabled: Bool {
        get { flag(genreMixesKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: genreMixesKey) }
    }

    /// Endless liked + nearby + unheard station card.
    static var nonstopEnabled: Bool {
        get { flag(nonstopKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: nonstopKey) }
    }

    static func vibeEnabled(_ vibe: MoodVibe) -> Bool {
        let defaults: Set<MoodVibe> = [.focus, .chill, .feelGood, .hype]
        return flag(vibeKey(vibe), default: defaults.contains(vibe))
    }

    static func setVibeEnabled(_ vibe: MoodVibe, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: vibeKey(vibe))
    }

    static var length: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: lengthKey)
            return v > 0 ? v : 40
        }
        set { UserDefaults.standard.set(newValue, forKey: lengthKey) }
    }

    /// Lowercased genre display names left out of every Made for you card.
    static var excludedGenres: Set<String> {
        get {
            Set((UserDefaults.standard.string(forKey: excludedGenresKey) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty })
        }
        set {
            UserDefaults.standard.set(
                newValue.sorted().joined(separator: "\n"),
                forKey: excludedGenresKey)
        }
    }

    /// Genres picked by hand for genre mixes; empty → follow listening.
    static var preferredGenres: [String] {
        get {
            (UserDefaults.standard.string(forKey: preferredGenresKey) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            UserDefaults.standard.set(newValue.joined(separator: "\n"), forKey: preferredGenresKey)
        }
    }

    static var anyShelfEnabled: Bool {
        daypartEnabled
            || discoveryEnabled
            || genreMixesEnabled
            || nonstopEnabled
            || shelfVibes.contains(where: vibeEnabled)
    }

    /// Fingerprint so Settings can rebuild when the user leaves the page.
    static var signature: String {
        let vibes = shelfVibes.map { vibeEnabled($0) ? "1" : "0" }.joined()
        let excluded = excludedGenres.sorted().joined(separator: ",")
        let preferred = preferredGenres.map { $0.lowercased() }.sorted().joined(separator: ",")
        return "\(daypartEnabled ? 1 : 0)\(discoveryEnabled ? 1 : 0)\(genreMixesEnabled ? 1 : 0)\(nonstopEnabled ? 1 : 0)\(vibes)|\(length)|\(excluded)|\(preferred)"
    }
}
