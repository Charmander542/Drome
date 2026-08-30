import Foundation

/// Shared selected vibe for the home tuner and Vibe Tuner widget.
enum WidgetVibeStore {
    static let appGroupID = WidgetRecentStore.appGroupID
    private static let selectedKey = "widget-vibe-selected"

    static var selectedVibe: MoodVibe {
        get {
            if let raw = UserDefaults(suiteName: appGroupID)?.string(forKey: selectedKey),
               let vibe = MoodVibe(rawValue: raw) {
                return vibe
            }
            return vibeForHour()
        }
        set {
            UserDefaults(suiteName: appGroupID)?.set(newValue.rawValue, forKey: selectedKey)
        }
    }

    static func vibeForHour() -> MoodVibe {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: return .focus
        case 11..<17: return .feelGood
        case 17..<21: return .hype
        default: return .lateNight
        }
    }
}
