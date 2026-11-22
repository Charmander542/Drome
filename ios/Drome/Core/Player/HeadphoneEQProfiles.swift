import Foundation
import AVFoundation

/// Per-output EQ curves so wired / Bluetooth / speaker each keep their own faders.
@MainActor
enum HeadphoneEQProfiles {
    private static let profilesKey = "drome.eqHeadphoneProfiles"
    private static let autoApplyKey = "drome.eqHeadphoneAutoApply"
    private static let activePortKey = "drome.eqHeadphoneActivePort"

    static let didChange = Notification.Name("drome.headphoneEQDidChange")

    struct Profile: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var bands: [Float]
        var preset: String
    }

    static var autoApply: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoApplyKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoApplyKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoApplyKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var profiles: [Profile] {
        get {
            guard let data = UserDefaults.standard.data(forKey: profilesKey),
                  let decoded = try? JSONDecoder().decode([Profile].self, from: data)
            else { return [] }
            return decoded.filter { $0.bands.count == AudioFXPreferences.bandFrequencies.count }
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: profilesKey)
            }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Current AVAudioSession output fingerprint (port UID, else name).
    static func currentPortKey() -> String? {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let primary = outs.first else { return nil }
        if !primary.uid.isEmpty { return primary.uid }
        return primary.portName
    }

    static func currentPortDisplayName() -> String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let primary = outs.first else { return "Speakers" }
        let name = primary.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? friendlyName(for: primary.portType) : name
    }

    static func profile(forPortKey key: String) -> Profile? {
        profiles.first { $0.id == key }
    }

    /// Persist the live EQ curve under the current output.
    static func saveCurrentOutputProfile(name: String? = nil) {
        guard let key = currentPortKey() else { return }
        let display = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (display?.isEmpty == false)
            ? display!
            : currentPortDisplayName()
        var list = profiles.filter { $0.id != key }
        list.append(Profile(
            id: key,
            name: resolved,
            bands: AudioFXPreferences.equalizerBands,
            preset: AudioFXPreferences.equalizerPreset
        ))
        profiles = list
        UserDefaults.standard.set(key, forKey: activePortKey)
    }

    static func clearProfile(portKey: String) {
        profiles = profiles.filter { $0.id != portKey }
    }

    /// Apply a stored profile for the active route when auto-apply is on.
    @discardableResult
    static func applyForCurrentRouteIfNeeded() -> Bool {
        guard autoApply, let key = currentPortKey() else { return false }
        let last = UserDefaults.standard.string(forKey: activePortKey)
        guard let profile = profile(forPortKey: key) else {
            UserDefaults.standard.set(key, forKey: activePortKey)
            return false
        }
        // Always re-apply when the port changes; skip if same port already active
        // and bands already match (avoids fighting manual fader edits).
        if last == key,
           AudioFXPreferences.equalizerBands == profile.bands {
            return false
        }
        AudioFXPreferences.equalizerBands = profile.bands
        AudioFXPreferences.equalizerPreset = profile.preset
        UserDefaults.standard.set(key, forKey: activePortKey)
        return true
    }

    private static func friendlyName(for type: AVAudioSession.Port) -> String {
        switch type {
        case .headphones: return "Headphones"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return "Bluetooth"
        case .builtInSpeaker: return "iPhone Speaker"
        case .airPlay: return "AirPlay"
        case .carAudio: return "Car"
        default: return type.rawValue
        }
    }
}
