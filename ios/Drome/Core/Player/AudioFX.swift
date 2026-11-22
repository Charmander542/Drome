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
/// Flat / near-flat gains are a no-op inside the tap (graph stays attached).
final class EqualizerProcessor {
    static let shared = EqualizerProcessor()
    static let bandCount = 5

    /// Same centers as `AudioFXPreferences.bandFrequencies` (copied for audio-thread use).
    let bandFrequencies: [Float] = [60, 230, 910, 3600, 14000]

    /// Fixed-size gain vector — audio thread copies these without allocating.
    private let lock = NSLock()
    private var gain0: Float = 0
    private var gain1: Float = 0
    private var gain2: Float = 0
    private var gain3: Float = 0
    private var gain4: Float = 0

    private init() {
        // Seed from prefs without hopping to MainActor during init.
        if let data = UserDefaults.standard.data(forKey: "drome.eqBands"),
           let decoded = try? JSONDecoder().decode([Float].self, from: data),
           decoded.count == Self.bandCount {
            applyGainsUnlocked(decoded)
        }
    }

    func updateGains(_ bands: [Float]) {
        lock.lock()
        applyGainsUnlocked(bands)
        lock.unlock()
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !gainsAreFlatUnlocked()
    }

    /// Attach the EQ mix on a player item (once, even when Flat).
    /// Prefer a synchronous attach so playback never starts dry then glitches
    /// when an async `audioMix` lands mid-buffer.
    func attach(to item: AVPlayerItem) {
        if item.audioMix != nil { return }

        // Local / warmed assets often already expose tracks.
        if let mix = makeMix(withAudioTracks: item.asset.tracks(withMediaType: .audio)) {
            item.audioMix = mix
            return
        }

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
        return makeMix(withAudioTracks: tracks)
    }

    private func makeMix(withAudioTracks tracks: [AVAssetTrack]) -> AVAudioMix? {
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
                // On failure leave source audio untouched; never drop frames to silence.
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

    fileprivate func copyGains(into out: inout (Float, Float, Float, Float, Float)) {
        lock.lock()
        out = (gain0, gain1, gain2, gain3, gain4)
        lock.unlock()
    }

    private func applyGainsUnlocked(_ bands: [Float]) {
        gain0 = bands.count > 0 ? bands[0] : 0
        gain1 = bands.count > 1 ? bands[1] : 0
        gain2 = bands.count > 2 ? bands[2] : 0
        gain3 = bands.count > 3 ? bands[3] : 0
        gain4 = bands.count > 4 ? bands[4] : 0
    }

    private func gainsAreFlatUnlocked() -> Bool {
        abs(gain0) < 0.05 && abs(gain1) < 0.05 && abs(gain2) < 0.05
            && abs(gain3) < 0.05 && abs(gain4) < 0.05
    }
}

// MARK: - Tap DSP

private final class TapStorage {
    private weak var processor: EqualizerProcessor?
    private var sampleRate: Double = 44100
    private var channelCount: Int = 2
    private var nonInterleaved = true
    private var isFloat = true
    /// Pre-sized in `prepare` — never reallocated on the audio thread.
    private var filters: [[Biquad]] = []
    private var smoothed: (Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0)
    private var lastCoeff: (Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0)
    /// Dry→wet mix (0 = bypass, 1 = full EQ). Fades in when EQ engages.
    private var wet: Float = 0

    /// ~80ms wet engage / release — short enough to avoid feeling like a dropout.
    private let wetSeconds: Float = 0.08
    /// ~60ms gain chase for preset changes.
    private let gainSeconds: Float = 0.06

    init(processor: EqualizerProcessor) {
        self.processor = processor
    }

    func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        _ = maxFrames
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100
        channelCount = max(1, Int(format.mChannelsPerFrame))
        nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
        wet = 0
        smoothed = (0, 0, 0, 0, 0)
        lastCoeff = smoothed
        // Allocate once here (prepare is off the realtime render path).
        let freqs = processor?.bandFrequencies ?? [60, 230, 910, 3600, 14000]
        filters = (0..<channelCount).map { _ in
            freqs.map { freq in
                Biquad.peaking(freq: freq, gainDB: 0, sampleRate: Float(sampleRate))
            }
        }
    }

    func unprepare() {
        filters.removeAll(keepingCapacity: true)
        wet = 0
    }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        // Integer PCM / unexpected formats: leave GetSourceAudio output alone.
        guard frameCount > 0, isFloat, let processor, !filters.isEmpty else { return }

        var target = (Float(0), Float(0), Float(0), Float(0), Float(0))
        processor.copyGains(into: &target)
        let targetActive = !tupleFlat(target)
        let targetWet: Float = targetActive ? 1 : 0

        let sr = Float(max(sampleRate, 1))
        let wetAlpha = 1 - exp(-Float(frameCount) / (wetSeconds * sr))
        let gainAlpha = 1 - exp(-Float(frameCount) / (gainSeconds * sr))
        wet += (targetWet - wet) * wetAlpha

        var gainsMoved = false
        gainsMoved = chase(&smoothed.0, toward: target.0, alpha: gainAlpha) || gainsMoved
        gainsMoved = chase(&smoothed.1, toward: target.1, alpha: gainAlpha) || gainsMoved
        gainsMoved = chase(&smoothed.2, toward: target.2, alpha: gainAlpha) || gainsMoved
        gainsMoved = chase(&smoothed.3, toward: target.3, alpha: gainAlpha) || gainsMoved
        gainsMoved = chase(&smoothed.4, toward: target.4, alpha: gainAlpha) || gainsMoved

        // Fully dry and settled → skip DSP (source audio already in the buffer).
        if wet < 0.001, !targetActive, tupleFlat(smoothed) {
            wet = 0
            return
        }

        if gainsMoved, tupleDelta(smoothed, lastCoeff) > 0.02 {
            updateCoefficientsInPlace(smoothed, freqs: processor.bandFrequencies)
            lastCoeff = smoothed
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
            let frames = min(
                frameCount,
                Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(channelCount, 1)))
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
        let bandCount = filters[channel].count
        for f in 0..<bandCount {
            var band = filters[channel][f]
            sample = band.process(sample)
            filters[channel][f] = band
        }
        return sample
    }

    /// Update peaking coeffs without reallocating filter arrays (audio-thread safe).
    private func updateCoefficientsInPlace(
        _ gains: (Float, Float, Float, Float, Float),
        freqs: [Float]
    ) {
        let sr = Float(sampleRate)
        let bandGains = (gains.0, gains.1, gains.2, gains.3, gains.4)
        for channel in 0..<filters.count {
            let count = min(filters[channel].count, EqualizerProcessor.bandCount, freqs.count)
            for i in 0..<count {
                let gain: Float
                switch i {
                case 0: gain = bandGains.0
                case 1: gain = bandGains.1
                case 2: gain = bandGains.2
                case 3: gain = bandGains.3
                default: gain = bandGains.4
                }
                var band = filters[channel][i]
                band.setPeaking(freq: freqs[i], gainDB: gain, sampleRate: sr)
                filters[channel][i] = band
            }
        }
    }

    @inline(__always)
    private func chase(_ value: inout Float, toward target: Float, alpha: Float) -> Bool {
        let next = value + (target - value) * alpha
        let moved = abs(next - value) > 0.0001
        value = next
        return moved
    }

    @inline(__always)
    private func tupleFlat(_ g: (Float, Float, Float, Float, Float)) -> Bool {
        abs(g.0) < 0.05 && abs(g.1) < 0.05 && abs(g.2) < 0.05
            && abs(g.3) < 0.05 && abs(g.4) < 0.05
    }

    @inline(__always)
    private func tupleDelta(
        _ a: (Float, Float, Float, Float, Float),
        _ b: (Float, Float, Float, Float, Float)
    ) -> Float {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2), abs(a.3 - b.3), abs(a.4 - b.4))
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
