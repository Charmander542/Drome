import Foundation
import AVFoundation

/// Persisted 5-band EQ + ReplayGain + crossfade preferences (Aura-class audio).
@MainActor
enum AudioFXPreferences {
    private static let replayGainKey = "drome.replayGainEnabled"
    private static let replayGainFallbackKey = "drome.replayGainFallback"
    private static let crossfadeKey = "drome.crossfadeSeconds"
    private static let prefetchKey = "drome.prefetchCount"
    private static let eqEnabledKey = "drome.eqEnabled"
    private static let eqBandsKey = "drome.eqBands"
    private static let eqPresetKey = "drome.eqPreset"
    private static let eqSavedKey = "drome.eqSavedSlots"
    private static let autoDownloadStarredKey = "drome.autoDownloadStarred"

    static let audioFXDidChange = Notification.Name("drome.audioFXDidChange")
    static let savedSlotCount = 3

    /// Frequencies for the five bands (Hz) — Aura-shaped.
    static let bandFrequencies: [Float] = [60, 230, 910, 3600, 14000]

    struct SavedEQSlot: Codable, Equatable, Identifiable {
        var id: Int
        var name: String
        var bands: [Float]
    }

    static var replayGainEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: replayGainKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: replayGainKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: replayGainKey)
            notify()
        }
    }

    /// dB applied when a track has no ReplayGain tags.
    static var replayGainFallbackDB: Float {
        get {
            let v = UserDefaults.standard.float(forKey: replayGainFallbackKey)
            return v == 0 && UserDefaults.standard.object(forKey: replayGainFallbackKey) == nil
                ? -6 : v
        }
        set {
            UserDefaults.standard.set(newValue, forKey: replayGainFallbackKey)
            notify()
        }
    }

    /// 0 = gapless only; 3…12 = crossfade seconds. Same-album stays gapless.
    static var crossfadeSeconds: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: crossfadeKey)
            return max(0, min(12, v))
        }
        set {
            UserDefaults.standard.set(max(0, min(12, newValue)), forKey: crossfadeKey)
            notify()
        }
    }

    /// How many upcoming tracks to pre-cache (Arpeggi-style).
    static var prefetchCount: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: prefetchKey)
            return v > 0 ? min(8, v) : 3
        }
        set {
            UserDefaults.standard.set(max(1, min(8, newValue)), forKey: prefetchKey)
            notify()
        }
    }

    static var equalizerEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: eqEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: eqEnabledKey)
            notify()
        }
    }

    /// Gain per band in dB (−12…+12).
    static var equalizerBands: [Float] {
        get {
            if let data = UserDefaults.standard.data(forKey: eqBandsKey),
               let decoded = try? JSONDecoder().decode([Float].self, from: data),
               decoded.count == bandFrequencies.count {
                return decoded
            }
            return Array(repeating: 0, count: bandFrequencies.count)
        }
        set {
            let clipped = newValue.prefix(bandFrequencies.count).map { max(-12, min(12, $0)) }
            if let data = try? JSONEncoder().encode(Array(clipped)) {
                UserDefaults.standard.set(data, forKey: eqBandsKey)
            }
            notify()
        }
    }

    static var equalizerPreset: String {
        get { UserDefaults.standard.string(forKey: eqPresetKey) ?? "Flat" }
        set { UserDefaults.standard.set(newValue, forKey: eqPresetKey) }
    }

    /// Up to three user-saved EQ curves (nil = empty slot).
    static var savedEqualizers: [SavedEQSlot?] {
        get {
            var slots: [SavedEQSlot?] = Array(repeating: nil, count: savedSlotCount)
            guard let data = UserDefaults.standard.data(forKey: eqSavedKey),
                  let decoded = try? JSONDecoder().decode([SavedEQSlot].self, from: data)
            else { return slots }
            for slot in decoded where slot.id >= 0 && slot.id < savedSlotCount {
                guard slot.bands.count == bandFrequencies.count else { continue }
                slots[slot.id] = slot
            }
            return slots
        }
        set {
            let clipped = newValue.enumerated().compactMap { index, slot -> SavedEQSlot? in
                guard var slot else { return nil }
                slot.id = index
                slot.bands = Array(slot.bands.prefix(bandFrequencies.count)).map { max(-12, min(12, $0)) }
                while slot.bands.count < bandFrequencies.count { slot.bands.append(0) }
                let trimmed = slot.name.trimmingCharacters(in: .whitespacesAndNewlines)
                slot.name = trimmed.isEmpty ? "EQ \(index + 1)" : trimmed
                return slot
            }
            if let data = try? JSONEncoder().encode(clipped) {
                UserDefaults.standard.set(data, forKey: eqSavedKey)
            }
            notify()
        }
    }

    static var autoDownloadStarred: Bool {
        get { UserDefaults.standard.bool(forKey: autoDownloadStarredKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoDownloadStarredKey) }
    }

    static let presets: [(String, [Float])] = [
        ("Flat", [0, 0, 0, 0, 0]),
        ("Bass Boost", [7, 4, 0, 0, 0]),
        ("Treble Boost", [0, 0, 1, 5, 7]),
        ("Vocal", [-2, 1, 4, 3, 0]),
        ("Electronic", [5, 2, -1, 3, 5]),
        ("Rock", [4, 2, -1, 2, 4]),
        ("Jazz", [3, 1, 0, 2, 3]),
        ("Classical", [3, 2, 0, 2, 4]),
        ("Loudness", [5, 2, -2, 2, 4]),
        ("Podcast", [-3, 0, 4, 5, 2]),
        ("Night", [2, 1, 0, -1, -3]),
        ("Acoustic", [3, 2, 1, 2, 3]),
        ("Dance", [6, 3, 0, 2, 5]),
        ("Hip-Hop", [7, 3, -1, 1, 3]),
        ("Custom", [0, 0, 0, 0, 0]),
    ]

    static func applyPreset(_ name: String) {
        guard let bands = presets.first(where: { $0.0 == name })?.1 else { return }
        equalizerPreset = name
        equalizerBands = bands
        if name != "Flat" { equalizerEnabled = true }
    }

    static func savedPresetKey(slot: Int) -> String { "saved:\(slot)" }

    static func savedSlotIndex(fromPreset name: String) -> Int? {
        guard name.hasPrefix("saved:") else { return nil }
        return Int(name.dropFirst("saved:".count))
    }

    /// Write the current fader curve into a slot (overwrites if occupied).
    static func saveCurrentEqualizer(to slot: Int, name: String? = nil) {
        guard slot >= 0, slot < savedSlotCount else { return }
        var slots = savedEqualizers
        let fallback = slots[slot]?.name ?? "EQ \(slot + 1)"
        let resolved = (name ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        slots[slot] = SavedEQSlot(
            id: slot,
            name: resolved.isEmpty ? "EQ \(slot + 1)" : resolved,
            bands: equalizerBands
        )
        savedEqualizers = slots
        equalizerPreset = savedPresetKey(slot: slot)
        equalizerEnabled = true
    }

    static func applySavedEqualizer(slot: Int) {
        guard slot >= 0, slot < savedSlotCount,
              let saved = savedEqualizers[slot] else { return }
        equalizerBands = saved.bands
        equalizerPreset = savedPresetKey(slot: slot)
        equalizerEnabled = true
    }

    static func renameSavedEqualizer(slot: Int, name: String) {
        guard slot >= 0, slot < savedSlotCount,
              var saved = savedEqualizers[slot] else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.name = trimmed.isEmpty ? "EQ \(slot + 1)" : trimmed
        var slots = savedEqualizers
        slots[slot] = saved
        savedEqualizers = slots
    }

    static func clearSavedEqualizer(slot: Int) {
        guard slot >= 0, slot < savedSlotCount else { return }
        var slots = savedEqualizers
        slots[slot] = nil
        savedEqualizers = slots
        if savedSlotIndex(fromPreset: equalizerPreset) == slot {
            equalizerPreset = "Custom"
        }
    }

    private static func notify() {
        NotificationCenter.default.post(name: audioFXDidChange, object: nil)
    }
}

/// Computes a linear volume multiplier from ReplayGain tags + EQ loudness tilt.
enum ReplayGain {
    /// Prefer track gain, then album, then fallback.
    static func gainDB(for song: Song) -> Float {
        if let track = song.replayGain?.trackGain { return track }
        if let album = song.replayGain?.albumGain { return album }
        // Called from MainActor contexts usually; fallback is a preference.
        return -6
    }

    static func linearGain(db: Float) -> Float {
        pow(10, db / 20)
    }

    /// Soft-clip so boosts don't explode the AVQueuePlayer volume.
    static func clampedVolume(gainDB: Float, eqTiltDB: Float = 0) -> Float {
        let linear = linearGain(db: gainDB + eqTiltDB)
        return min(1.25, max(0.15, linear))
    }
}

/// Applies ReplayGain + a coarse EQ tilt to AVQueuePlayer.volume.
@MainActor
final class AudioFXController {
    static let shared = AudioFXController()

    /// Average of mid/high bands as a simple loudness tilt when full AU EQ isn't wired.
    var eqTiltDB: Float {
        guard AudioFXPreferences.equalizerEnabled else { return 0 }
        let bands = AudioFXPreferences.equalizerBands
        guard bands.count >= 5 else { return 0 }
        // Weight bass + presence lightly so the 5-band UI is audible via volume.
        return (bands[0] * 0.15 + bands[1] * 0.1 + bands[2] * 0.05
                + bands[3] * 0.08 + bands[4] * 0.12)
    }

    func volume(for song: Song?) -> Float {
        guard let song else { return 1 }
        var gain: Float = 0
        if AudioFXPreferences.replayGainEnabled {
            if let track = song.replayGain?.trackGain {
                gain = track
            } else if let album = song.replayGain?.albumGain {
                gain = album
            } else {
                gain = AudioFXPreferences.replayGainFallbackDB
            }
        }
        return ReplayGain.clampedVolume(gainDB: gain, eqTiltDB: eqTiltDB)
    }
}
