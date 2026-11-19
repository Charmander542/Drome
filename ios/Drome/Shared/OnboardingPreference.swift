import Foundation

/// First-run feature tour — keyed per Navidrome user so account switches
/// each get a walkthrough once.
enum OnboardingPreference {
    private static let prefix = "drome.onboarding.completed."

    static func storageKey(for userKey: String) -> String {
        prefix + userKey
    }

    static func hasCompleted(userKey: String) -> Bool {
        UserDefaults.standard.bool(forKey: storageKey(for: userKey))
    }

    static func markCompleted(userKey: String) {
        UserDefaults.standard.set(true, forKey: storageKey(for: userKey))
    }

    static func reset(userKey: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(for: userKey))
    }
}
