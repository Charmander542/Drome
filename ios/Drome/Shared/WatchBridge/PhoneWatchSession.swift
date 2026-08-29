#if os(iOS)
import Foundation
import WatchConnectivity

/// iPhone → Apple Watch playback mirror and remote control.
@MainActor
final class PhoneWatchSession: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchSession()

    enum BroadcastPriority {
        /// Play/pause/skip — small JSON only, always instant.
        case transport
        /// Scrubber position — JSON only, ~1 Hz.
        case playhead
        /// Track change — JSON + artwork when available.
        case full
    }

    private var observersInstalled = false
    private var lastPlayheadLiveAt: TimeInterval = 0
    private var lastPlayheadSignature: String?
    private var lastArtworkSongId: String?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        installObserversIfNeeded()
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func broadcast(
        session: AppSession?,
        database: AppDatabase?,
        priority: BroadcastPriority
    ) {
        if let session, let database {
            WidgetRecentSync.writeNowPlayingSnapshot(session: session, database: database)
        }
        guard WCSession.default.activationState == .activated else { return }
        guard let message = outboundMessage(
            session: session,
            database: database,
            priority: priority)
        else { return }
        pushLive(message, priority: priority)
        pushContext(message, priority: priority)
    }

    func pushFromStoredSnapshot() {
        let env = AppEnvironment.shared
        broadcast(session: env?.session, database: env?.database, priority: .full)
    }

    func pushSnapshot(session: AppSession?, database: AppDatabase?) {
        broadcast(session: session, database: database, priority: .full)
    }

    /// Snapshot for Watch command replies — no extra network send (reply carries it).
    func syncReply(session: AppSession?, database: AppDatabase?) -> [String: Any] {
        if let session, let database {
            WidgetRecentSync.writeNowPlayingSnapshot(session: session, database: database)
        }
        return outboundMessage(
            session: session,
            database: database,
            priority: .transport) ?? ["ok": true]
    }

    // MARK: - Packaging

    private func outboundMessage(
        session: AppSession?,
        database: AppDatabase?,
        priority: BroadcastPriority
    ) -> [String: Any]? {
        guard let json = snapshotJSON(session: session, database: database) else { return nil }
        var message: [String: Any] = [
            WatchBridgeKey.snapshotJSON: json,
            "ok": true,
        ]
        if priority == .full, let payload = decodePayload(json) {
            message.merge(artworkFields(for: payload)) { _, new in new }
        }
        return message
    }

    private func pushContext(_ message: [String: Any], priority: BroadcastPriority) {
        var context = message
        if priority != .full {
            context.removeValue(forKey: WatchBridgeKey.artworkJPEG)
            context.removeValue(forKey: WatchBridgeKey.artworkSongId)
        }
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            DromeDiagnostics.log("watch context failed: \(error.localizedDescription)")
        }
    }

    private func pushLive(_ message: [String: Any], priority: BroadcastPriority) {
        let wcSession = WCSession.default
        guard wcSession.isReachable else { return }

        if priority == .playhead {
            let signature = playheadSignature(in: message)
            let now = Date().timeIntervalSince1970
            if signature == lastPlayheadSignature, now - lastPlayheadLiveAt < 0.85 { return }
            lastPlayheadSignature = signature
            lastPlayheadLiveAt = now
        }

        var live = message
        if priority != .full {
            live.removeValue(forKey: WatchBridgeKey.artworkJPEG)
            live.removeValue(forKey: WatchBridgeKey.artworkSongId)
        }

        wcSession.sendMessage(live, replyHandler: nil) { error in
            DromeDiagnostics.log("watch live message failed: \(error.localizedDescription)")
        }
    }

    private func playheadSignature(in message: [String: Any]) -> String {
        guard let json = message[WatchBridgeKey.snapshotJSON] as? String,
              let payload = decodePayload(json),
              let np = payload.nowPlaying
        else { return "empty" }
        return [
            np.songId,
            np.isPlaying ? "1" : "0",
            String(Int(np.elapsed)),
        ].joined(separator: "|")
    }

    private func snapshotJSON(session: AppSession?, database: AppDatabase?) -> String? {
        let widgetSnap = WidgetRecentStore.load()
        let playlists: [WatchPlaylistItem]
        if let session {
            let serverKey = session.account.serverKey
            playlists = (LibraryListCatalog.playlists(serverKey: serverKey) ?? [])
                .prefix(24)
                .map { WatchPlaylistItem(id: $0.id, name: $0.name, songCount: $0.songCount ?? 0) }
        } else {
            playlists = []
        }

        var payload = WatchPlaybackPayload.fromWidgetSnapshot(
            widgetSnap,
            playlists: Array(playlists))
        if payload.updatedAt == 0 {
            payload.updatedAt = Date().timeIntervalSince1970
        }

        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodePayload(_ json: String) -> WatchPlaybackPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WatchPlaybackPayload.self, from: data)
    }

    private func artworkFields(for payload: WatchPlaybackPayload) -> [String: Any] {
        guard let songId = payload.artworkSongId else { return [:] }
        guard songId != lastArtworkSongId else { return [:] }
        guard let jpeg = watchArtworkJPEG(for: songId) else { return [:] }
        lastArtworkSongId = songId
        return [
            WatchBridgeKey.artworkJPEG: jpeg,
            WatchBridgeKey.artworkSongId: songId,
        ]
    }

    private func watchArtworkJPEG(for songId: String) -> Data? {
        let widgetSnap = WidgetRecentStore.load()
        var candidates: [String] = []
        if widgetSnap.nowPlaying?.songId == songId, let file = widgetSnap.nowPlaying?.artworkFile {
            candidates.append(file)
        }
        candidates.append("song-\(Self.sanitizedSongId(songId)).jpg")

        for file in candidates {
            guard let url = WidgetRecentStore.artworkURL(for: file),
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data)
            else { continue }
            return image.watchJPEGThumbnail(maxSide: 120)
        }
        return nil
    }

    private static func sanitizedSongId(_ raw: String) -> String {
        raw.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - Inbound commands

    func handleIncomingMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?
    ) -> [String: Any] {
        guard let raw = message[WatchBridgeKey.command] as? String,
              let command = WatchCommand(rawValue: raw)
        else {
            let reply: [String: Any] = ["ok": true]
            replyHandler?(reply)
            return reply
        }

        if command == .requestSync {
            let env = AppEnvironment.shared
            let reply = syncReply(session: env?.session, database: env?.database)
            replyHandler?(reply)
            return reply
        }

        guard let appSession = AppEnvironment.shared?.session else {
            let reply: [String: Any] = ["ok": false]
            replyHandler?(reply)
            return reply
        }

        switch command {
        case .togglePlay:
            appSession.handleWidgetCommand(.togglePlay)
        case .next:
            appSession.handleWidgetCommand(.next)
        case .previous:
            appSession.handleWidgetCommand(.previous)
        case .toggleLike:
            appSession.handleWidgetCommand(.toggleLike)
        case .toggleOutOfRotation:
            appSession.handleWidgetCommand(.toggleOutOfRotation)
        case .setRating:
            guard let rating = message[WatchBridgeKey.rating] as? Int,
                  let song = appSession.player.current?.song else { break }
            appSession.ratings.setRating(rating, for: song)
            WidgetRecentSync.refresh(session: appSession, database: appSession.database)
        case .playContext:
            guard let resumeKey = message[WatchBridgeKey.resumeKey] as? String,
                  let entryId = message[WatchBridgeKey.entryId] as? String else { break }
            let songId = message[WatchBridgeKey.songId] as? String
            Task {
                await AppEnvironment.shared?.playWatchContext(
                    resumeKey: resumeKey,
                    entryId: entryId,
                    songId: songId)
            }
        case .playPlaylist:
            guard let playlistId = message[WatchBridgeKey.playlistId] as? String else { break }
            Task {
                await AppEnvironment.shared?.playWatchPlaylist(id: playlistId)
            }
        case .adjustVolume:
            let delta = message[WatchBridgeKey.volumeDelta] as? Float ?? 0.08
            SystemVolumeController.adjust(by: delta)
        case .requestSync:
            break
        }

        let reply = syncReply(session: appSession, database: appSession.database)
        replyHandler?(reply)
        return reply
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        NotificationCenter.default.addObserver(
            forName: .dromeSessionChanged,
            object: nil,
            queue: .main
        ) { _ in
            PhoneWatchSession.shared.broadcast(
                session: AppEnvironment.shared?.session,
                database: AppEnvironment.shared?.database,
                priority: .full)
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            PhoneWatchSession.shared.pushFromStoredSnapshot()
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        DispatchQueue.main.async {
            PhoneWatchSession.shared.pushFromStoredSnapshot()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        DispatchQueue.main.async {
            PhoneWatchSession.shared.pushFromStoredSnapshot()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        guard session.isWatchAppInstalled else { return }
        DispatchQueue.main.async {
            PhoneWatchSession.shared.pushFromStoredSnapshot()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            _ = PhoneWatchSession.shared.handleIncomingMessage(message, replyHandler: nil)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        DispatchQueue.main.async {
            _ = PhoneWatchSession.shared.handleIncomingMessage(message, replyHandler: replyHandler)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        DispatchQueue.main.async {
            _ = PhoneWatchSession.shared.handleIncomingMessage(userInfo, replyHandler: nil)
        }
    }
}

/// Adjusts iPhone media volume for Watch remote buttons / crown helpers.
enum SystemVolumeController {
    private static let volumeView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.showsRouteButton = false
        return view
    }()

    static func attachIfNeeded() {
        guard volumeView.superview == nil,
              let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return }
        window.addSubview(volumeView)
    }

    static func adjust(by delta: Float) {
        attachIfNeeded()
        let current = AVAudioSession.sharedInstance().outputVolume
        setVolume(min(1, max(0, current + delta)))
    }

    private static func setVolume(_ value: Float) {
        attachIfNeeded()
        DispatchQueue.main.async {
            if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
                slider.value = value
            }
        }
    }
}

import AVFoundation
import MediaPlayer
import UIKit

private extension UIImage {
    func watchJPEGThumbnail(maxSide: CGFloat) -> Data? {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.78)
    }
}
#endif
