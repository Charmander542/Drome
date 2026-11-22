import Foundation
import AVFoundation
import MediaToolbox

/// Persisted 5-band EQ + ReplayGain + crossfade preferences (Aura-class audio).
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
               let decoded = try? JSONDecoder().decode([Float].self, from: data),
               decoded.count == bandFrequencies.count {
                return decoded
            }
            return Array(repeating: 0, count: bandFrequencies.count)
        }
        set {
            let clipped = Array(newValue.prefix(bandFrequencies.count).map { max(-12, min(12, $0)) })
            if let data = try? JSONEncoder().encode(clipped) {
                UserDefaults.standard.set(data, forKey: eqBandsKey)
            }
            UserDefaults.standard.set(!bandsAreFlat(clipped), forKey: eqEnabledKey)
            EqualizerProcessor.shared.updateGains(clipped)
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

// MARK: - Real 5-band EQ (PCM tap on AVPlayerItem)

/// Attaches an `AVAudioMix` processing tap that runs five peaking EQ bands.
/// Flat / near-flat gains clear the mix so the tap is bypassed.
final class EqualizerProcessor {
    static let shared = EqualizerProcessor()

    /// Same centers as `AudioFXPreferences.bandFrequencies` (copied for audio-thread use).
    let bandFrequencies: [Float] = [60, 230, 910, 3600, 14000]

    private let lock = NSLock()
    private var gains: [Float]
    /// Bumped on every fader/preset change so the audio tap only rebuilds coeffs then.
    private(set) var gainsGeneration: UInt64 = 0

    private init() {
        gains = Array(repeating: 0, count: bandFrequencies.count)
        // Seed from prefs without hopping to MainActor during init.
        if let data = UserDefaults.standard.data(forKey: "drome.eqBands"),
           let decoded = try? JSONDecoder().decode([Float].self, from: data),
           decoded.count == bandFrequencies.count {
            gains = decoded
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
    private var smoothedGains: [Float] = Array(repeating: 0, count: 5)
    /// Dry→wet mix (0 = bypass, 1 = full EQ). Fades in when EQ engages.
    private var wet: Float = 0
    private var lastCoeffGains: [Float] = Array(repeating: 0, count: 5)

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
        smoothedGains = Array(repeating: 0, count: 5)
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
        let f = freqs ?? processor?.bandFrequencies ?? [60, 230, 910, 3600, 14000]
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
