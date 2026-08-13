import AVFoundation

/// Synthesized launch sting — three soft bass thuds across the splash
/// (~1.55s, matching the animated overlay). No audio asset required.
final class BootChime {
    static let shared = BootChime()

    /// Keep in sync with `SplashScreenView.totalDuration`.
    static let duration: Double = 1.55

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private var didStart = false
    private let lock = NSLock()

    private init() {}

    /// Plays the boot sting. Safe to call even if audio setup fails.
    func play() {
        lock.lock()
        defer { lock.unlock() }

        startIfNeeded()
        guard engine.isRunning, let buffer = budumpBuffer() else { return }

        if player.isPlaying {
            player.stop()
        }
        player.scheduleBuffer(buffer, at: nil)
        player.play()
    }

    private func startIfNeeded() {
        guard !didStart else { return }
        didStart = true

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Don't steal PlayerEngine's .playback session — only claim ambient
        // when nothing else has configured audio yet.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.ambient, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        try? engine.start()
    }

    /// Three spaced thuds that fill the splash: bu → dump → boom.
    private func budumpBuffer() -> AVAudioPCMBuffer? {
        let duration = Self.duration
        let capacity = AVAudioFrameCount(duration * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let channel = buffer.floatChannelData?[0]
        else {
            return nil
        }
        buffer.frameLength = capacity
        let count = Int(capacity)

        for frame in 0..<count {
            channel[frame] = 0
        }

        // Bu — deep open
        renderHit(
            into: channel,
            frameCount: count,
            start: 0.00,
            fundamental: 58,
            amplitude: 0.52,
            decay: 6.5,
            noiseAmount: 0.32,
            hitDuration: 0.55
        )
        // Dump — mid punch
        renderHit(
            into: channel,
            frameCount: count,
            start: 0.48,
            fundamental: 87,
            amplitude: 0.58,
            decay: 7.5,
            noiseAmount: 0.40,
            hitDuration: 0.55
        )
        // Boom — resolving low hit into the fade-out
        renderHit(
            into: channel,
            frameCount: count,
            start: 0.98,
            fundamental: 52,
            amplitude: 0.64,
            decay: 5.5,
            noiseAmount: 0.38,
            hitDuration: 0.55
        )

        return buffer
    }

    private func renderHit(
        into channel: UnsafeMutablePointer<Float>,
        frameCount: Int,
        start: Double,
        fundamental: Double,
        amplitude: Float,
        decay: Double,
        noiseAmount: Double,
        hitDuration: Double
    ) {
        let startFrame = Int(start * sampleRate)
        guard startFrame < frameCount else { return }
        let frames = min(Int(hitDuration * sampleRate), frameCount - startFrame)

        for i in 0..<frames {
            let frame = startFrame + i
            let t = Double(i) / sampleRate
            let attack = min(1.0, t / 0.014)
            let envelope = attack * exp(-decay * t)

            let sub = sin(2.0 * .pi * fundamental * t)
            let body = 0.55 * sin(2.0 * .pi * fundamental * 2.0 * t)
            let mid = 0.28 * sin(2.0 * .pi * fundamental * 3.0 * t)
            let noiseEnv = exp(-55.0 * t)
            let noise = (Double.random(in: -1...1)) * noiseAmount * noiseEnv

            let sample = (sub + body + mid + noise) * envelope
            channel[frame] += Float(sample) * amplitude
        }
    }
}
