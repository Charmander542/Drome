#if os(tvOS)
import AVFoundation
import Foundation

/// File playback that does not go through FigFilePlayer (AVPlayer).
/// Used when a complete MP3 is already on disk.
final class TVNowPlayingAudio: NSObject, AVAudioPlayerDelegate {
    var onFinished: (() -> Void)?

    private var player: AVAudioPlayer?

    var isActive: Bool { player != nil }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval {
        let value = player?.duration ?? 0
        return value.isFinite && value > 0 ? value : 0
    }

    func start(url: URL) throws {
        stop()
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.delegate = self
        audio.volume = 1
        audio.prepareToPlay()
        player = audio
        guard audio.play() else {
            player = nil
            throw URLError(.cannotDecodeContentData)
        }
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), max(player.duration - 0.05, 0))
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.onFinished?()
        }
    }
}
#endif
