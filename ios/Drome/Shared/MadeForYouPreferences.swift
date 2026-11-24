import Foundation

/// Settings for the on-device Made for you shelf (Home).
///
/// Defaults keep a tight rail: daypart + a few vibes + fresh finds.
/// Companion Daily Mixes stay separate when a wishlist server is attached.
enum MadeForYouPreferences {
    private static let prefix = "drome.mfy."

    static let daypartKey = prefix + "daypart"
    static let discoveryKey = prefix + "discovery"
    static let lengthKey = prefix + "length"
    static let excludedGenresKey = prefix + "excludedGenres"

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

    static var anyShelfEnabled: Bool {
        daypartEnabled
            || discoveryEnabled
            || shelfVibes.contains(where: vibeEnabled)
    }

    /// Fingerprint so Settings can rebuild when the user leaves the page.
    static var signature: String {
        let vibes = shelfVibes.map { vibeEnabled($0) ? "1" : "0" }.joined()
        let excluded = excludedGenres.sorted().joined(separator: ",")
        return "\(daypartEnabled ? 1 : 0)\(discoveryEnabled ? 1 : 0)\(vibes)|\(length)|\(excluded)"
    }
}
