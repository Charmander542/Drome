import Foundation

/// Sonora-style radio steering for Infinite Shuffle / vibe autoplay.
enum StationSteering: String, CaseIterable, Identifiable, Codable {
    case balanced
    case familiar
    case discovery
    case keepVibe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .familiar: return "More Familiar"
        case .discovery: return "More Discovery"
        case .keepVibe: return "Keep This Vibe"
        }
    }

    var blurb: String {
        switch self {
        case .balanced: return "Favorites blended with fresh picks"
        case .familiar: return "Lean on what you already love"
        case .discovery: return "Hunt newer and less-played tracks"
        case .keepVibe: return "Lock genre, energy, and era"
        }
    }

    var symbol: String {
        switch self {
        case .balanced: return "slider.horizontal.3"
        case .familiar: return "heart.fill"
        case .discovery: return "sparkles"
        case .keepVibe: return "lock.fill"
        }
    }
}

@MainActor
enum StationSteeringStore {
    private static let key = "drome.stationSteering"

    static var current: StationSteering {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let value = StationSteering(rawValue: raw) else {
                return .balanced
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .dromeStationSteeringDidChange, object: newValue)
        }
    }
}

extension Notification.Name {
    static let dromeStationSteeringDidChange = Notification.Name("drome.stationSteeringDidChange")
}
