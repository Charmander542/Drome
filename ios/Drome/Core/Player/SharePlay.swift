import AVFoundation
import Foundation
import GroupActivities
import UIKit

/// FaceTime / Messages SharePlay activity. Each device plays from its own
/// Navidrome login. Playback time stays in sync via AVPlayer; queue changes
/// (play, skip, add, reorder) are broadcast so anyone can drive the jam.
struct DromeListenTogether: GroupActivity {
    static var activityIdentifier: String { "drome.app.listenTogether" }

    var title: String
    var subtitle: String

    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = title.isEmpty ? "Jam" : title
        meta.subtitle = subtitle.isEmpty ? "Listen together" : subtitle
        meta.type = .listenTogether
        return meta
    }
}

struct SharePlayTrack: Codable, Equatable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String?

    init(song: Song) {
        id = song.id
        title = song.title
        artist = song.displayArtist
        album = song.album
    }
}

struct SharePlaySnapshot: Codable, Equatable {
    var current: SharePlayTrack
    var upcoming: [SharePlayTrack]
    var sentAt: TimeInterval
    var isPlaying: Bool

    init(current: SharePlayTrack, upcoming: [SharePlayTrack], sentAt: TimeInterval = Date().timeIntervalSince1970, isPlaying: Bool = true) {
        self.current = current
        self.upcoming = upcoming
        self.sentAt = sentAt
        self.isPlaying = isPlaying
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decode(SharePlayTrack.self, forKey: .current)
        upcoming = try container.decode([SharePlayTrack].self, forKey: .upcoming)
        sentAt = try container.decodeIfPresent(TimeInterval.self, forKey: .sentAt) ?? 0
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? true
    }

    static func == (lhs: SharePlaySnapshot, rhs: SharePlaySnapshot) -> Bool {
        lhs.current == rhs.current && lhs.upcoming == rhs.upcoming
    }
}

/// Maps each `AVPlayerItem` to a title|artist identity so participants can
/// coordinate even when Navidrome stream URLs (and song ids) differ.
extension AVCoordinatedPlaybackSuspension.Reason {
    static let dromeRebuilding = AVCoordinatedPlaybackSuspension.Reason(rawValue: "drome.app.rebuilding")
}

final class SharePlayCoordinatorBridge: NSObject, AVPlayerPlaybackCoordinatorDelegate {
    private let lock = NSLock()
    private var ids: [ObjectIdentifier: String] = [:]

    func remember(_ item: AVPlayerItem, identity: String) {
        lock.lock()
        ids[ObjectIdentifier(item)] = identity
        lock.unlock()
    }

    func reset() {
        lock.lock()
        ids.removeAll()
        lock.unlock()
    }

    func playbackCoordinator(
        _ coordinator: AVPlayerPlaybackCoordinator,
        identifierFor playerItem: AVPlayerItem
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        return ids[ObjectIdentifier(playerItem)] ?? ""
    }
}

enum SharePlayLauncher {
    @MainActor
    static func start(from engine: PlayerEngine) {
        guard engine.current?.song != nil else { return }
        let activity = DromeListenTogether(
            title: engine.current?.song.title ?? "Jam",
            subtitle: engine.current?.song.displayArtist ?? "Listen together")
        Task { @MainActor in
            if engine.isEligibleForSharePlay {
                await activateInFaceTime(activity, engine: engine)
            } else {
                do {
                    let picker = try await GroupActivitySharingController(activity)
                    topViewController()?.present(picker, animated: true)
                    engine.sharePlayNotice = Self.jamExplainer
                } catch {
                    await activateInFaceTime(activity, engine: engine)
                }
            }
        }
    }

    @MainActor
    private static func activateInFaceTime(_ activity: DromeListenTogether, engine: PlayerEngine) async {
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            do {
                _ = try await activity.activate()
                engine.sharePlayNotice = Self.jamExplainer
            } catch {
                engine.sharePlayNotice = "Couldn’t start the jam. Ask the other person to open Drome, or use FaceTime Share Screen to send audio into the call."
            }
        default:
            engine.sharePlayNotice = "Start a FaceTime call first. Jam plays in Drome on each phone — it doesn’t send audio through the call. Use Share Screen for that."
        }
    }

    static let jamExplainer = "Jam plays on each phone in Drome (both need the app). FaceTime won’t carry the music — use Share Screen if you want the call to hear your speaker."

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
