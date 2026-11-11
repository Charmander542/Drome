import Foundation
import MediaPlayer

/// Single in-app owner of audible playback.
///
/// Music and podcast each have their own `AVPlayer`. The shared `AVAudioSession`
/// does not serialize them — without an owner, Bluetooth interruptions and
/// stacked remote-command handlers can resume both at once (or flip Now Playing
/// metadata / CarPlay transport controls).
@MainActor
enum AudioFocusOwner: Equatable {
    case none
    case music
    case podcast
}

@MainActor
final class AudioFocus {
    static let shared = AudioFocus()

    /// Posted on the main actor whenever `owner` changes.
    static let didChangeNotification = Notification.Name("drome.audioFocusDidChange")

    private(set) var owner: AudioFocusOwner = .none
    /// Last non-`.none` owner — used so vacant-focus remote Play only wakes
    /// the engine that was listening (not both).
    private(set) var lastOwner: AudioFocusOwner = .none

    func claim(_ next: AudioFocusOwner) {
        guard next != .none else {
            releaseAll()
            return
        }
        lastOwner = next
        guard owner != next else {
            applyRemoteCommandSurface()
            return
        }
        owner = next
        DromeDiagnostics.logPlayer("audioFocus → \(label(next))")
        applyRemoteCommandSurface()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func release(_ source: AudioFocusOwner) {
        guard owner == source else { return }
        owner = .none
        DromeDiagnostics.logPlayer("audioFocus → none (released \(label(source)))")
        applyRemoteCommandSurface()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func releaseAll() {
        guard owner != .none else { return }
        owner = .none
        DromeDiagnostics.logPlayer("audioFocus → none")
        applyRemoteCommandSurface()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func isOwner(_ source: AudioFocusOwner) -> Bool {
        owner == source
    }

    /// Drop sticky last-owner after a source fully tears down (e.g. podcast
    /// `stop()` cleared the episode) so the other engine can reclaim remote Play.
    func forgetLastOwner(_ source: AudioFocusOwner) {
        if lastOwner == source {
            lastOwner = .none
        }
    }

    /// Whether `source` may handle Play / toggle while focus is vacant or owned.
    func allowsRemotePlayback(for source: AudioFocusOwner) -> Bool {
        switch owner {
        case .music: return source == .music
        case .podcast: return source == .podcast
        case .none:
            if lastOwner == .none { return true }
            return lastOwner == source
        }
    }

    /// Enable the transport surface that matches the current owner so CarPlay /
    /// lock screen never show music next/prev while a podcast owns audio (and
    /// vice versa). Both engines still register handlers; they no-op unless
    /// they own focus — this just toggles which buttons the system presents.
    func applyRemoteCommandSurface() {
        #if !os(tvOS)
        let center = MPRemoteCommandCenter.shared()
        switch owner {
        case .music:
            center.playCommand.isEnabled = true
            center.pauseCommand.isEnabled = true
            center.togglePlayPauseCommand.isEnabled = true
            center.nextTrackCommand.isEnabled = true
            center.previousTrackCommand.isEnabled = true
            center.changePlaybackPositionCommand.isEnabled = true
            center.skipForwardCommand.isEnabled = false
            center.skipBackwardCommand.isEnabled = false
            center.skipForwardCommand.preferredIntervals = []
            center.skipBackwardCommand.preferredIntervals = []
        case .podcast:
            center.playCommand.isEnabled = true
            center.pauseCommand.isEnabled = true
            center.togglePlayPauseCommand.isEnabled = true
            center.nextTrackCommand.isEnabled = false
            center.previousTrackCommand.isEnabled = false
            center.changePlaybackPositionCommand.isEnabled = true
            center.skipForwardCommand.isEnabled = true
            center.skipBackwardCommand.isEnabled = true
            center.skipForwardCommand.preferredIntervals = [30]
            center.skipBackwardCommand.preferredIntervals = [15]
        case .none:
            // Keep play/pause available so a stale Now Playing tile can resume
            // whichever engine still has content; leave skips/next off.
            center.playCommand.isEnabled = true
            center.pauseCommand.isEnabled = true
            center.togglePlayPauseCommand.isEnabled = true
            center.nextTrackCommand.isEnabled = false
            center.previousTrackCommand.isEnabled = false
            center.skipForwardCommand.isEnabled = false
            center.skipBackwardCommand.isEnabled = false
            center.changePlaybackPositionCommand.isEnabled = false
        }
        #endif
    }

    private func label(_ owner: AudioFocusOwner) -> String {
        switch owner {
        case .none: return "none"
        case .music: return "music"
        case .podcast: return "podcast"
        }
    }
}
