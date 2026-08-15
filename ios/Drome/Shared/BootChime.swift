import AVFoundation

/// Launch sting — first two seconds of the bundled hip-hop drum loop.
final class BootChime {
    static let shared = BootChime()

    /// Keep in sync with `SplashScreenView.totalDuration` (minus the still hold).
    static let duration: Double = 2.0

    private var player: AVAudioPlayer?
    private let lock = NSLock()

    private init() {}

    /// Plays the boot sting. Safe to call even if audio setup fails.
    func play() {
        lock.lock()
        defer { lock.unlock() }

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
}
