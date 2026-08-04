import Foundation
import MediaPlayer
import UIKit

/// Bridges the player engine to the system: lock screen / Control Center
/// metadata (MPNowPlayingInfoCenter) and remote commands. CarPlay's
/// Now Playing template feeds off the same data automatically.
@MainActor
final class NowPlayingCenter {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?

    private var artwork: MPMediaItemArtwork?
    private var artworkSongID: String?

    func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.onPlay?(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onPlay?(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNext?(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevious?(); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onSeek?(event.positionTime)
            return .success
        }
    }

    func setArtwork(_ image: UIImage?, songID: String?) {
        artworkSongID = songID
        if let image {
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else {
            artwork = nil
        }
    }

    func update(song: Song?, elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard let song else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? "",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork, artworkSongID == song.id {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
