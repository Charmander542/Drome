import AVFoundation
import CoreHaptics
import UIKit

/// Launch intro: bundled drum loop, or a haptic transcription of the same hits.
enum LaunchIntroPreference {
    static let hapticKey = "drome.launchIntroHaptic"

    static var usesHaptics: Bool {
        get { UserDefaults.standard.bool(forKey: hapticKey) }
        set { UserDefaults.standard.set(newValue, forKey: hapticKey) }
    }
}

/// Launch sting — first two seconds of the bundled hip-hop drum loop,
/// or an equivalent haptic pattern timed to those transients.
final class BootChime {
    static let shared = BootChime()

    /// Keep in sync with `SplashScreenView.totalDuration` (minus the still hold).
    static let duration: Double = 2.0

    private var player: AVAudioPlayer?
    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticPatternPlayer?
    private var fallbackWork: [DispatchWorkItem] = []
    private let lock = NSLock()

    private init() {}

    /// Plays the boot sting. Safe to call even if audio/haptic setup fails.
    func play() {
        if LaunchIntroPreference.usesHaptics {
            playHaptic()
        } else {
            playAudio()
        }
    }

    private func playAudio() {
        lock.lock()
        defer { lock.unlock() }
        cancelFallbackLocked()

        guard let url = Bundle.main.url(forResource: "BootChime", withExtension: "m4a") else {
            return
        }

        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.ambient, options: [.mixWithOthers])
            try? session.setActive(true)
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            player.play()
        } catch {
            self.player = nil
        }
    }

    private func playHaptic() {
        lock.lock()
        defer { lock.unlock() }
        cancelFallbackLocked()
        player?.stop()
        player = nil

        if CHHapticEngine.capabilitiesForHardware().supportsHaptics,
           let player = makePatternPlayer() {
            do {
                try hapticEngine?.start()
                try player.start(atTime: 0)
                hapticPlayer = player
                return
            } catch {
                hapticPlayer = nil
            }
        }
        playUIKitFallbackLocked()
    }

    /// Onsets from the 2s loop: kick 0.03, hats 0.40, snare 0.75, kick 1.10, snare 1.48, hats 1.83.
    private func makePatternPlayer() -> CHHapticPatternPlayer? {
        do {
            if hapticEngine == nil {
                let engine = try CHHapticEngine()
                engine.resetHandler = { [weak self] in
                    try? self?.hapticEngine?.start()
                }
                hapticEngine = engine
            }
            try hapticEngine?.start()

            var events: [CHHapticEvent] = []
            var curves: [CHHapticParameterCurve] = []

            func kick(at time: TimeInterval, intensity: Float) {
                events.append(CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.18),
                    ],
                    relativeTime: time
                ))
                let rumble: TimeInterval = 0.18
                events.append(CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity * 0.7),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.12),
                    ],
                    relativeTime: time,
                    duration: rumble
                ))
                curves.append(CHHapticParameterCurve(
                    parameterID: .hapticIntensityControl,
                    controlPoints: [
                        CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: intensity),
                        CHHapticParameterCurve.ControlPoint(relativeTime: rumble, value: 0.04),
                    ],
                    relativeTime: time
                ))
            }

            func snare(at time: TimeInterval, intensity: Float) {
                events.append(CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.52),
                    ],
                    relativeTime: time
                ))
                let body: TimeInterval = 0.16
                events.append(CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity * 0.55),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
                    ],
                    relativeTime: time,
                    duration: body
                ))
                curves.append(CHHapticParameterCurve(
                    parameterID: .hapticIntensityControl,
                    controlPoints: [
                        CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: intensity * 0.7),
                        CHHapticParameterCurve.ControlPoint(relativeTime: body, value: 0.05),
                    ],
                    relativeTime: time
                ))
            }

            func hats(at time: TimeInterval, intensity: Float) {
                events.append(CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.92),
                    ],
                    relativeTime: time
                ))
            }

            kick(at: 0.03, intensity: 1.0)
            hats(at: 0.40, intensity: 0.22)
            snare(at: 0.75, intensity: 0.82)
            kick(at: 1.10, intensity: 0.95)
            snare(at: 1.48, intensity: 1.0)
            hats(at: 1.83, intensity: 0.2)

            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            return try hapticEngine?.makePlayer(with: pattern)
        } catch {
            return nil
        }
    }

    private func playUIKitFallbackLocked() {
        let hits: [(TimeInterval, UIImpactFeedbackGenerator.FeedbackStyle, CGFloat)] = [
            (0.03, .heavy, 1.0),
            (0.10, .medium, 0.45),
            (0.40, .light, 0.28),
            (0.75, .heavy, 0.85),
            (0.82, .medium, 0.4),
            (1.10, .heavy, 0.95),
            (1.18, .medium, 0.4),
            (1.48, .heavy, 1.0),
            (1.83, .light, 0.25),
        ]
        let generators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [
            .heavy: UIImpactFeedbackGenerator(style: .heavy),
            .medium: UIImpactFeedbackGenerator(style: .medium),
            .light: UIImpactFeedbackGenerator(style: .light),
        ]
        generators.values.forEach { $0.prepare() }

        for (delay, style, intensity) in hits {
            let work = DispatchWorkItem {
                generators[style]?.impactOccurred(intensity: intensity)
            }
            fallbackWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelFallbackLocked() {
        fallbackWork.forEach { $0.cancel() }
        fallbackWork.removeAll()
        try? hapticPlayer?.stop(atTime: 0)
        hapticPlayer = nil
    }
}
