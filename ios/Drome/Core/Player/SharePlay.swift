import AVFoundation
import Foundation
import GroupActivities
import UIKit

/// FaceTime SharePlay activity. Keep this payload empty and stable so both
/// phones always subscribe to the same `sessions()` stream.
struct DromeListenTogether: GroupActivity {
    static let activityIdentifier = "drome.app.listenTogether"

    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = "Drome Jam"
        meta.subtitle = "Listen together in Drome"
        meta.type = .generic
        return meta
    }
}

/// Guest asks the host to send the current queue. GroupSessionMessenger does
/// not replay earlier messages to late joiners.
struct SharePlayCatchUp: Codable, Equatable {
    var token: String
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

extension AVCoordinatedPlaybackSuspension.Reason {
    static let dromeRebuilding = AVCoordinatedPlaybackSuspension.Reason(rawValue: "drome.app.rebuilding")
}

/// Maps each `AVPlayerItem` to a title|artist identity so participants can
/// coordinate even when Navidrome stream URLs (and song ids) differ.
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

/// Single app-wide `sessions()` subscriber. Cancelling that loop (or starting
/// a second one) drops FaceTime sessions on the floor.
@MainActor
final class SharePlayRuntime {
    static let shared = SharePlayRuntime()

    private var listenTask: Task<Void, Never>?
    private weak var engine: PlayerEngine?
    private var pendingSession: GroupSession<DromeListenTogether>?

    func startListening() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            for await session in DromeListenTogether.sessions() {
                self?.deliver(session)
            }
        }
    }

    func bind(_ engine: PlayerEngine?) {
        self.engine = engine
        if let pendingSession, let engine {
            self.pendingSession = nil
            engine.attachSharePlaySession(pendingSession)
        }
    }

    private func deliver(_ session: GroupSession<DromeListenTogether>) {
        if let engine {
            engine.attachSharePlaySession(session)
        } else {
            pendingSession = session
        }
    }
}

enum SharePlayLauncher {
    @MainActor
    static func start(from engine: PlayerEngine) {
        SharePlayRuntime.shared.startListening()
        let activity = DromeListenTogether()
        Task { @MainActor in
            if engine.isEligibleForSharePlay {
                await activateInFaceTime(activity, engine: engine)
                return
            }
            if engine.current?.song == nil {
                engine.sharePlayNotice = "Play a song, start a FaceTime call, then tap Start on both phones."
                return
            }
            do {
                let picker = try await GroupActivitySharingController(activity)
                guard let host = topViewController() else {
                    await activateInFaceTime(activity, engine: engine)
                    return
                }
                host.present(picker, animated: true)
                engine.sharePlayNotice = "Pick the FaceTime call, then they tap Join in Drome."
            } catch {
                await activateInFaceTime(activity, engine: engine)
            }
        }
    }

    @MainActor
    private static func activateInFaceTime(_ activity: DromeListenTogether, engine: PlayerEngine) async {
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            do {
                let started = try await activity.activate()
                if started {
                    engine.sharePlayNotice = "They have to tap Start / Join in Drome on this FaceTime — just opening the app isn’t enough."
                } else {
                    engine.sharePlayNotice = "FaceTime didn’t start SharePlay. Try Start again, or share Drome from the FaceTime SharePlay button."
                }
            } catch {
                engine.sharePlayNotice = "Couldn’t join the jam. Both of you: FaceTime + Drome open, then tap Start."
            }
        default:
            engine.sharePlayNotice = "Start FaceTime first. Then both of you tap Start on Now Playing."
        }
    }

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
