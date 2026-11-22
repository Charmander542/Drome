import Foundation
import AVFoundation
import MediaToolbox

/// Persisted 10-band EQ + ReplayGain + crossfade preferences (Aura-class audio).
/// Flat faders = EQ off; any non-flat curve = EQ on (no separate toggle).
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

    /// Standard 10-band graphic EQ centers (Hz).
    static let bandFrequencies: [Float] = [
        32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    private static let legacyFiveBandFrequencies: [Float] = [60, 230, 910, 3600, 14000]

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

    private static let mixTransitionKey = "drome.mixTransitionMode"

    enum MixTransitionMode: String, CaseIterable, Identifiable {
        case off
        case soft
        case beatAligned

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .soft: return "Soft"
            case .beatAligned: return "Beat-aligned"
            }
        }

        var detail: String {
            switch self {
            case .off: return "Gapless only (same album always gapless)"
            case .soft: return "Volume ramp between unrelated tracks"
            case .beatAligned: return "Snap crossfade length to an estimated beat grid"
            }
        }
    }

    /// Soft / beat-aligned mix transitions. `off` forces crossfadeSeconds to 0 at read sites.
    static var mixTransitionMode: MixTransitionMode {
        get {
            let raw = UserDefaults.standard.string(forKey: mixTransitionKey) ?? ""
            if let mode = MixTransitionMode(rawValue: raw) { return mode }
            // Migrate: previous installs used crossfadeSeconds alone.
            return crossfadeSeconds > 0 ? .soft : .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: mixTransitionKey)
            if newValue == .off {
                UserDefaults.standard.set(0, forKey: crossfadeKey)
            } else if crossfadeSeconds == 0 {
                UserDefaults.standard.set(6, forKey: crossfadeKey)
            }
            notify()
        }
    }

    /// Effective crossfade length after mix-mode + optional beat snapping.
    static func resolvedCrossfadeSeconds(for song: Song?) -> Int {
        let mode = mixTransitionMode
        guard mode != .off else { return 0 }
        var seconds = crossfadeSeconds
        if seconds <= 0 { seconds = 6 }
        if mode == .beatAligned {
            seconds = beatAlignedSeconds(base: seconds, song: song)
        }
        return max(3, min(12, seconds))
    }

    /// Assume ~120 BPM (0.5s/beat) unless duration implies a different energy.
    private static func beatAlignedSeconds(base: Int, song: Song?) -> Int {
        let beat: Double
        if let duration = song?.duration, duration > 0 {
            // Prefer ~0.5s beats; nudge with track length so short radio edits
            // don't get a sluggish 12s wash.
            beat = duration < 150 ? 0.45 : 0.5
        } else {
            beat = 0.5
        }
        let beats = max(4, Int((Double(base) / beat).rounded()))
        let snapped = Int((Double(beats) * beat).rounded())
        return max(3, min(12, snapped))
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

    /// On when any fader is off Flat. Setting false resets to Flat.
    static var equalizerEnabled: Bool {
        get { !bandsAreFlat(equalizerBands) }
        set {
            if !newValue {
                equalizerPreset = "Flat"
                equalizerBands = Array(repeating: 0, count: bandFrequencies.count)
            }
            UserDefaults.standard.set(newValue && !bandsAreFlat(equalizerBands), forKey: eqEnabledKey)
        }
    }

    static func bandsAreFlat(_ bands: [Float]) -> Bool {
        bands.allSatisfy { abs($0) < 0.05 }
    }

    /// Gain per band in dB (−12…+12).
    static var equalizerBands: [Float] {
        get {
            if let data = UserDefaults.standard.data(forKey: eqBandsKey),
               let decoded = try? JSONDecoder().decode([Float].self, from: data) {
                if decoded.count == bandFrequencies.count {
                    return decoded
                }
                if decoded.count == legacyFiveBandFrequencies.count {
                    return migrateFiveBandCurve(decoded)
                }
            }
            return Array(repeating: 0, count: bandFrequencies.count)
        }
        set {
            var clipped = Array(newValue.prefix(bandFrequencies.count).map { max(-12, min(12, $0)) })
            while clipped.count < bandFrequencies.count { clipped.append(0) }
            if let data = try? JSONEncoder().encode(clipped) {
                UserDefaults.standard.set(data, forKey: eqBandsKey)
            }
            UserDefaults.standard.set(!bandsAreFlat(clipped), forKey: eqEnabledKey)
            EqualizerProcessor.shared.updateGains(clipped)
            notify()
        }
    }

    /// Linear interpolate a legacy 5-band curve onto the 10-band centers.
    private static func migrateFiveBandCurve(_ five: [Float]) -> [Float] {
        guard five.count == legacyFiveBandFrequencies.count else {
            return Array(repeating: 0, count: bandFrequencies.count)
        }
        return bandFrequencies.map { targetHz in
            if let exact = zip(legacyFiveBandFrequencies, five).first(where: { abs($0.0 - targetHz) < 0.5 }) {
                return exact.1
            }
            // Find surrounding legacy bands in log-frequency space.
            let logT = log(max(targetHz, 1))
            var lower = (legacyFiveBandFrequencies[0], five[0])
            var upper = (legacyFiveBandFrequencies[fourCountSafe], five[fourCountSafe])
            for i in 0..<legacyFiveBandFrequencies.count {
                let hz = legacyFiveBandFrequencies[i]
                if hz <= targetHz { lower = (hz, five[i]) }
                if hz >= targetHz {
                    upper = (hz, five[i])
                    break
                }
            }
            if lower.0 == upper.0 { return lower.1 }
            let logL = log(max(lower.0, 1))
            let logU = log(max(upper.0, 1))
            let t = (logT - logL) / max(logU - logL, 0.0001)
            return lower.1 + Float(t) * (upper.1 - lower.1)
        }
    }

    private static var fourCountSafe: Int { max(0, legacyFiveBandFrequencies.count - 1) }

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
                var migrated = slot
                if migrated.bands.count == legacyFiveBandFrequencies.count {
                    migrated.bands = migrateFiveBandCurve(migrated.bands)
                }
                guard migrated.bands.count == bandFrequencies.count else { continue }
                slots[slot.id] = migrated
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

    /// 10-band presets (32…16k). Values in dB.
    static let presets: [(String, [Float])] = [
        ("Flat",        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost",  [8, 7, 5, 3, 1, 0, 0, 0, 0, 0]),
        ("Treble Boost",[0, 0, 0, 0, 0, 1, 2, 4, 6, 7]),
        ("Vocal",       [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1]),
        ("Electronic",  [6, 5, 3, 0, -2, 0, 2, 4, 5, 4]),
        ("Rock",        [5, 4, 3, 1, -1, 0, 2, 3, 4, 3]),
        ("Jazz",        [3, 2, 1, 0, 0, 1, 2, 2, 3, 2]),
        ("Classical",   [4, 3, 2, 1, 0, 0, 1, 2, 3, 4]),
        ("Loudness",    [6, 5, 3, 1, -2, -1, 1, 2, 4, 5]),
        ("Podcast",     [-4, -2, 0, 2, 4, 5, 4, 2, 0, -1]),
        ("Night",       [2, 2, 1, 0, 0, -1, -1, -2, -3, -4]),
        ("Acoustic",    [3, 3, 2, 1, 1, 1, 2, 2, 3, 2]),
        ("Dance",       [7, 6, 4, 1, 0, 0, 2, 3, 5, 4]),
        ("Hip-Hop",     [8, 7, 4, 1, -1, 0, 1, 2, 3, 2]),
        ("Custom",      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ]

    static func applyPreset(_ name: String) {
        guard let bands = presets.first(where: { $0.0 == name })?.1 else { return }
        equalizerPreset = name
        equalizerBands = bands
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
    }

    static func applySavedEqualizer(slot: Int) {
        guard slot >= 0, slot < savedSlotCount,
              let saved = savedEqualizers[slot] else { return }
        equalizerBands = saved.bands
        equalizerPreset = savedPresetKey(slot: slot)
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


extension AudioFXPreferences {
    /// Nonisolated upsample for EqualizerProcessor cold start (mirrors private migrate).
    nonisolated static func migrateFiveBandCurveForProcessor(_ five: [Float]) -> [Float] {
        let legacy: [Float] = [60, 230, 910, 3600, 14000]
        let targets: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        guard five.count == legacy.count else {
            return Array(repeating: 0, count: targets.count)
        }
        return targets.map { targetHz in
            if let exact = zip(legacy, five).first(where: { abs($0.0 - targetHz) < 0.5 }) {
                return exact.1
            }
            let logT = log(max(targetHz, 1))
            var lower = (legacy[0], five[0])
            var upper = (legacy[legacy.count - 1], five[five.count - 1])
            for i in 0..<legacy.count {
                if legacy[i] <= targetHz { lower = (legacy[i], five[i]) }
                if legacy[i] >= targetHz {
                    upper = (legacy[i], five[i])
                    break
                }
            }
            if lower.0 == upper.0 { return lower.1 }
            let logL = log(max(lower.0, 1))
            let logU = log(max(upper.0, 1))
            let t = (logT - logL) / max(logU - logL, 0.0001)
            return lower.1 + Float(t) * (upper.1 - lower.1)
        }
    }
}

/// Computes a linear volume multiplier from ReplayGain tags.
enum ReplayGain {
    /// Prefer track gain, then album, then fallback.
    static func gainDB(for song: Song) -> Float {
        if let track = song.replayGain?.trackGain { return track }
        if let album = song.replayGain?.albumGain { return album }
        return -6
    }

    static func linearGain(db: Float) -> Float {
        pow(10, db / 20)
    }

    /// Soft-clip so boosts don't explode AVQueuePlayer.volume (0…1).
    static func clampedVolume(gainDB: Float) -> Float {
        let linear = linearGain(db: gainDB)
        return min(1.0, max(0.15, linear))
    }
}

/// Applies ReplayGain to AVQueuePlayer.volume (EQ is a real PCM tap, not volume).
@MainActor
final class AudioFXController {
    static let shared = AudioFXController()

    func volume(for song: Song?) -> Float {
        guard let song else { return 1 }
        guard AudioFXPreferences.replayGainEnabled else { return 1 }
        let gain: Float
        if let track = song.replayGain?.trackGain {
            gain = track
        } else if let album = song.replayGain?.albumGain {
            gain = album
        } else {
            gain = AudioFXPreferences.replayGainFallbackDB
        }
        return ReplayGain.clampedVolume(gainDB: gain)
    }
}

// MARK: - Real 10-band EQ (PCM tap on AVPlayerItem)

/// Attaches an `AVAudioMix` processing tap that runs ten peaking EQ bands.
/// Flat / near-flat gains clear the mix so the tap is bypassed.
final class EqualizerProcessor {
    static let shared = EqualizerProcessor()

    /// Same centers as `AudioFXPreferences.bandFrequencies` (copied for audio-thread use).
    let bandFrequencies: [Float] = [
        32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    private let lock = NSLock()
    private var gains: [Float]
    /// Bumped on every fader/preset change so the audio tap only rebuilds coeffs then.
    private(set) var gainsGeneration: UInt64 = 0

    private init() {
        gains = Array(repeating: 0, count: bandFrequencies.count)
        // Seed from prefs without hopping to MainActor during init.
        if let data = UserDefaults.standard.data(forKey: "drome.eqBands"),
           let decoded = try? JSONDecoder().decode([Float].self, from: data) {
            if decoded.count == bandFrequencies.count {
                gains = decoded
            } else if decoded.count == 5 {
                // Rough upsample until MainActor prefs migrate on first read.
                gains = AudioFXPreferences.migrateFiveBandCurveForProcessor(decoded)
            }
        }
    }

    func updateGains(_ bands: [Float]) {
        lock.lock()
        gains = bands
        gainsGeneration &+= 1
        lock.unlock()
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !gains.allSatisfy { abs($0) < 0.05 }
    }

    /// Attach the EQ mix on a player item (once, even when Flat).
    /// Live fader moves only update shared gains — never recreate or tear down
    /// `audioMix` on a playing item (that clicks/scratches). Flat curves are a
    /// no-op inside the tap, so the graph stays put across Flat ↔ EQ.
    func attach(to item: AVPlayerItem) {
        // Already processing via an existing tap that reads live gains.
        if item.audioMix != nil { return }

        let asset = item.asset
        Task { [weak item] in
            let mix = await makeMix(for: asset)
            await MainActor.run {
                guard let item, item.audioMix == nil else { return }
                item.audioMix = mix
            }
        }
    }

    private func makeMix(for asset: AVAsset) async -> AVAudioMix? {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return nil
        }
        guard let track = tracks.first else { return nil }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { tap, clientInfo, tapStorageOut in
                let processor = Unmanaged<EqualizerProcessor>.fromOpaque(clientInfo!).takeUnretainedValue()
                let storage = TapStorage(processor: processor)
                tapStorageOut.pointee = Unmanaged.passRetained(storage).toOpaque()
                _ = tap
            },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<TapStorage>.fromOpaque(storage).release()
            },
            prepare: { tap, maxFrames, processingFormat in
                let storagePtr = MTAudioProcessingTapGetStorage(tap)
                let storage = Unmanaged<TapStorage>.fromOpaque(storagePtr).takeUnretainedValue()
                storage.prepare(maxFrames: Int(maxFrames), format: processingFormat.pointee)
            },
            unprepare: { tap in
                let storagePtr = MTAudioProcessingTapGetStorage(tap)
                let storage = Unmanaged<TapStorage>.fromOpaque(storagePtr).takeUnretainedValue()
                storage.unprepare()
            },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                var localFlags: MTAudioProcessingTapFlags = 0
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    numberFrames,
                    bufferListInOut,
                    &localFlags,
                    nil,
                    numberFramesOut)
                flagsOut.pointee = localFlags
                guard status == noErr else { return }

                let storagePtr = MTAudioProcessingTapGetStorage(tap)
                let storage = Unmanaged<TapStorage>.fromOpaque(storagePtr).takeUnretainedValue()
                storage.process(bufferList: bufferListInOut, frameCount: Int(numberFramesOut.pointee))
                _ = flags
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap)
        guard status == noErr, let tap else { return nil }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

// MARK: - Tap DSP

private final class TapStorage {
    private weak var processor: EqualizerProcessor?
    private var sampleRate: Double = 44100
    private var channelCount: Int = 2
    private var nonInterleaved = true
    private var filters: [[Biquad]] = []
    /// Smoothed toward the UI target so preset / fader snaps don't jump.
    private var smoothedGains: [Float] = Array(repeating: 0, count: 10)
    /// Dry→wet mix (0 = bypass, 1 = full EQ). Fades in when EQ engages.
    private var wet: Float = 0
    private var lastCoeffGains: [Float] = Array(repeating: 0, count: 10)

    /// ~120ms wet engage / release — audible fade without feeling sluggish.
    private let wetSeconds: Float = 0.12
    /// ~80ms gain chase for preset changes.
    private let gainSeconds: Float = 0.08

    init(processor: EqualizerProcessor) {
        self.processor = processor
    }

    func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        _ = maxFrames
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100
        channelCount = max(1, Int(format.mChannelsPerFrame))
        nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        // Start dry so first attach fades EQ in instead of slamming it on.
        wet = 0
        let bandCount = processor?.bandFrequencies.count ?? 10
        smoothedGains = Array(repeating: 0, count: bandCount)
        lastCoeffGains = smoothedGains
        rebuildFilters(gains: smoothedGains, freqs: processor?.bandFrequencies)
    }

    func unprepare() {
        filters.removeAll()
        wet = 0
    }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0, let processor else { return }
        let snapshot = processor.currentSnapshot()
        let targetGains = snapshot.gains
        let targetActive = !targetGains.allSatisfy { abs($0) < 0.05 }
        let targetWet: Float = targetActive ? 1 : 0

        let sr = Float(max(sampleRate, 1))
        let wetAlpha = 1 - exp(-Float(frameCount) / (wetSeconds * sr))
        let gainAlpha = 1 - exp(-Float(frameCount) / (gainSeconds * sr))
        wet += (targetWet - wet) * wetAlpha

        var gainsMoved = false
        if smoothedGains.count != targetGains.count {
            smoothedGains = targetGains
            gainsMoved = true
        } else {
            for i in 0..<smoothedGains.count {
                let next = smoothedGains[i] + (targetGains[i] - smoothedGains[i]) * gainAlpha
                if abs(next - smoothedGains[i]) > 0.0001 { gainsMoved = true }
                smoothedGains[i] = next
            }
        }

        // Fully dry and settled → skip DSP.
        if wet < 0.001, !targetActive,
           smoothedGains.allSatisfy({ abs($0) < 0.05 }) {
            wet = 0
            return
        }

        let structureBad = filters.isEmpty || filters.count != channelCount
        if structureBad || (gainsMoved && maxAbsDelta(smoothedGains, lastCoeffGains) > 0.02) {
            rebuildFilters(gains: smoothedGains, freqs: processor.bandFrequencies)
            lastCoeffGains = smoothedGains
        }

        let mix = min(1, max(0, wet))
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        if nonInterleaved {
            for (channel, buffer) in abl.enumerated() {
                guard channel < filters.count,
                      let data = buffer.mData?.assumingMemoryBound(to: Float.self)
                else { continue }
                let count = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                processChannel(data: data, count: count, channel: channel, wet: mix)
            }
        } else if let buffer = abl.first,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
            let frames = min(frameCount, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(channelCount, 1)))
            for i in 0..<frames {
                for ch in 0..<min(channelCount, filters.count) {
                    let idx = i * channelCount + ch
                    data[idx] = blend(dry: data[idx], channel: ch, wet: mix)
                }
            }
        }
    }

    private func processChannel(
        data: UnsafeMutablePointer<Float>, count: Int, channel: Int, wet: Float
    ) {
        for i in 0..<count {
            data[i] = blend(dry: data[i], channel: channel, wet: wet)
        }
    }

    /// Keep filter state continuous; crossfade dry↔EQ so engages don't jump.
    private func blend(dry: Float, channel: Int, wet: Float) -> Float {
        let eq = processSample(dry, channel: channel)
        let mixed = dry + wet * (eq - dry)
        return max(-1, min(1, mixed))
    }

    private func processSample(_ x: Float, channel: Int) -> Float {
        var sample = x
        guard channel < filters.count else { return sample }
        for f in 0..<filters[channel].count {
            sample = filters[channel][f].process(sample)
        }
        return sample
    }

    private func rebuildFilters(gains: [Float]? = nil, freqs: [Float]? = nil) {
        let g = gains ?? smoothedGains
        let f = freqs ?? processor?.bandFrequencies ?? [
            32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
        ]
        // Keep delay state when only gains change to avoid clicks.
        let previous = filters
        filters = (0..<channelCount).map { channel in
            zip(f, g).enumerated().map { index, pair in
                var biquad = Biquad.peaking(
                    freq: pair.0, gainDB: pair.1, sampleRate: Float(sampleRate))
                if channel < previous.count, index < previous[channel].count {
                    biquad.z1 = previous[channel][index].z1
                    biquad.z2 = previous[channel][index].z2
                }
                return biquad
            }
        }
    }

    private func maxAbsDelta(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var best: Float = 0
        for i in 0..<a.count {
            best = max(best, abs(a[i] - b[i]))
        }
        return best
    }
}

private extension EqualizerProcessor {
    struct Snapshot {
        var gains: [Float]
        var generation: UInt64
    }

    func currentSnapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(gains: gains, generation: gainsGeneration)
    }
}

/// RBJ cookbook peaking EQ (Direct Form I).
private struct Biquad {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0
    var z1: Float = 0
    var z2: Float = 0

    static func peaking(freq: Float, gainDB: Float, sampleRate: Float, q: Float = 1.1) -> Biquad {
        var b = Biquad()
        b.setPeaking(freq: freq, gainDB: gainDB, sampleRate: sampleRate, q: q)
        return b
    }

    mutating func setPeaking(freq: Float, gainDB: Float, sampleRate: Float, q: Float = 1.1) {
        if abs(gainDB) < 0.05 {
            b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0
            return
        }
        let A = pow(10 as Float, gainDB / 40)
        let w0 = 2 * Float.pi * (freq / max(sampleRate, 1))
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let b0n = 1 + alpha * A
        let b1n = -2 * cosw
        let b2n = 1 - alpha * A
        let a0n = 1 + alpha / A
        let a1n = -2 * cosw
        let a2n = 1 - alpha / A
        b0 = b0n / a0n
        b1 = b1n / a0n
        b2 = b2n / a0n
        a1 = a1n / a0n
        a2 = a2n / a0n
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
