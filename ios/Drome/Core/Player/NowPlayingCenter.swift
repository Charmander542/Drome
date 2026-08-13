import Foundation
import MediaPlayer
import UIKit

/// Bridges the player engine to the system: lock screen / Control Center
/// metadata (MPNowPlayingInfoCenter) and remote commands. CarPlay's
/// Now Playing template feeds off the same data — including the foreground
/// album-art tile (not just the blurred background).
@MainActor
final class NowPlayingCenter {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?

    private var artwork: MPMediaItemArtwork?
    private var artworkSongID: String?
    private var artworkImage: UIImage?

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
        artworkImage = image
        guard let image, songID != nil else {
            artwork = nil
            artworkImage = nil
            return
        }
        // CarPlay / Lock Screen request specific sizes via the handler. Returning
        // a properly scaled square for each request is what makes the foreground
        // album tile appear (blurred background alone is not enough).
        let maxSide = max(image.size.width * image.scale, image.size.height * image.scale, 1024)
        let bounds = CGSize(width: maxSide, height: maxSide)
        // Capture the bitmap — the request handler may run off the main actor.
        let source = image
        artwork = MPMediaItemArtwork(boundsSize: bounds) { requested in
            Self.squared(source, to: requested)
        }
    }

    func update(song: Song?, elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard let song else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        // Merge into existing info so a transient update can't drop other keys,
        // but always re-assert (or clear) artwork for the active song.
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = song.album ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        if let artwork, artworkSongID == song.id {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Square, letterboxed image at the size CarPlay/Lock Screen asked for.
    private static func squared(_ image: UIImage, to size: CGSize) -> UIImage {
        let target = CGSize(
            width: max(size.width, 1),
            height: max(size.height, 1))
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            let scale = min(
                target.width / max(image.size.width, 1),
                target.height / max(image.size.height, 1))
            let drawSize = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale)
            let origin = CGPoint(
                x: (target.width - drawSize.width) / 2,
                y: (target.height - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
