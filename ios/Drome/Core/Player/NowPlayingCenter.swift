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
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?

    private var artwork: MPMediaItemArtwork?
    private var artworkSongID: String?
    private var artworkImage: UIImage?
    private var commandsConfigured = false

    func configureCommands() {
        guard !commandsConfigured else { return }
        commandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        // Strict ownership checks — both music and podcast register handlers on
        // the shared center; previously `!= .other` let both fire when focus
        // was `.none`, which flipped transport + Now Playing after CarPlay /
        // Bluetooth handoffs.
        center.playCommand.addTarget { [weak self] _ in
            guard Self.musicCommandsAllowed else { return .commandFailed }
            self?.onPlay?()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard AudioFocus.shared.isOwner(.music) else { return .commandFailed }
            self?.onPause?()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard Self.musicCommandsAllowed else { return .commandFailed }
            if let onToggle = self?.onToggle {
                onToggle()
            } else {
                self?.onPlay?()
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard AudioFocus.shared.isOwner(.music) else { return .commandFailed }
            self?.onNext?()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard AudioFocus.shared.isOwner(.music) else { return .commandFailed }
            self?.onPrevious?()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard AudioFocus.shared.isOwner(.music) else { return .commandFailed }
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.onSeek?(event.positionTime)
            return .success
        }
        AudioFocus.shared.applyRemoteCommandSurface()
    }

    func setArtwork(_ image: UIImage?, songID: String?) {
        artworkSongID = songID
        artworkImage = image
        guard let image, songID != nil else {
            artwork = nil
            artworkImage = nil
            return
        }
        // The system Now Playing widget sizes its tile from the bitmap we
        // return. A non-square request (or a wide cover) used to make that
        // tile rectangular. Always hand back a center-cropped square.
        let source = image
        artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 1024, height: 1024)) { requested in
            let side = min(max(requested.width, requested.height, 1), 1024)
            return Self.squareFilled(source, side: side)
        }
    }

    func update(song: Song?, elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard let song else {
            // Only clear the system tile when music still owns focus — otherwise
            // a music pause/yield would wipe the podcast Now Playing card.
            if AudioFocus.shared.isOwner(.music) || AudioFocus.shared.owner == .none {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            return
        }
        guard AudioFocus.shared.isOwner(.music) else { return }

        // Merge into existing info so a transient update can't drop other keys,
        // but always re-assert (or clear) artwork for the active song.
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = song.album ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        if let artwork, artworkSongID == song.id {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static var musicCommandsAllowed: Bool {
        AudioFocus.shared.allowsRemotePlayback(for: .music)
    }

    /// Center-cropped square. The canvas is always `side` × `side`, even when
    /// the system asks for a rectangle or the source cover is not square.
    /// The artwork request handler runs off the main actor.
    nonisolated static func squareFilled(_ image: UIImage, side: CGFloat) -> UIImage {
        let side = max(side, 1)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format)
        return renderer.image { _ in
            let src = image.size
            let scale = max(side / max(src.width, 1), side / max(src.height, 1))
            let drawSize = CGSize(width: src.width * scale, height: src.height * scale)
            let origin = CGPoint(
                x: (side - drawSize.width) / 2,
                y: (side - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
