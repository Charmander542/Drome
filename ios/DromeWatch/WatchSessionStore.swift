import Foundation
import WatchConnectivity
import Combine

@MainActor
final class WatchSessionStore: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionStore()

    @Published private(set) var payload: WatchPlaybackPayload = .empty
    @Published private(set) var isReachable = false
    @Published private(set) var isPhoneConnected = false
    @Published private(set) var isActivated = false
    @Published private(set) var lastSyncError: String?
    @Published private(set) var artworkEpoch: UInt = 0

    private var pendingOutbound: [[String: Any]] = []
    private var contextPollTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            lastSyncError = "WatchConnectivity unavailable"
            return
        }
        WatchWidgetCommandBridge.startObserving { command in
            WatchSessionStore.shared.send(command.watchCommand)
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ command: WatchCommand, extras: [String: Any] = [:]) {
        applyOptimistic(command)

        var message = extras
        message[WatchBridgeKey.command] = command.rawValue
        let session = WCSession.default
        guard session.activationState == .activated else {
            pendingOutbound.append(message)
            return
        }
        transmit(message, session: session)
    }

    func requestSync() {
        let session = WCSession.default
        guard session.activationState == .activated else {
            pendingOutbound.append([WatchBridgeKey.command: WatchCommand.requestSync.rawValue])
            return
        }

        ingest(session.receivedApplicationContext)

        guard session.isReachable else { return }
        session.sendMessage(
            [WatchBridgeKey.command: WatchCommand.requestSync.rawValue],
            replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    self?.ingest(reply)
                }
            },
            errorHandler: { [weak self] error in
                DispatchQueue.main.async {
                    self?.lastSyncError = error.localizedDescription
                }
            })
    }

    func refreshFromPhone() {
        refreshConnectionState(WCSession.default)
        ingest(WCSession.default.receivedApplicationContext)
        requestSync()
    }

    func startContextPolling() {
        contextPollTask?.cancel()
        contextPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    refreshConnectionState(WCSession.default)
                    ingest(WCSession.default.receivedApplicationContext)
                }
            }
        }
    }

    func stopContextPolling() {
        contextPollTask?.cancel()
        contextPollTask = nil
    }

    func artworkData(for songId: String?) -> Data? {
        guard let songId, let url = WatchArtStore.artworkURL(for: songId) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Transport

    private func transmit(_ message: [String: Any], session: WCSession) {
        guard session.isReachable else {
            session.transferUserInfo(message)
            return
        }
        session.sendMessage(
            message,
            replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    self?.ingest(reply)
                }
            },
            errorHandler: { [weak session] _ in
                session?.transferUserInfo(message)
            })
    }

    private func flushPending() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let queue = pendingOutbound
        pendingOutbound.removeAll()
        for message in queue {
            if message[WatchBridgeKey.command] as? String == WatchCommand.requestSync.rawValue {
                requestSync()
            } else {
                transmit(message, session: session)
            }
        }
    }

    // MARK: - State

    private func ingest(_ message: [String: Any]) {
        lastSyncError = nil
        if let json = message[WatchBridgeKey.snapshotJSON] as? String {
            applySnapshotJSON(json)
        }
        applyArtwork(from: message)
    }

    private func applySnapshotJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let incoming = try? JSONDecoder().decode(WatchPlaybackPayload.self, from: data)
        else { return }

        guard shouldAccept(incoming) else { return }

        let artMissing = artworkData(for: incoming.artworkSongId) == nil
        payload = incoming
        WatchWidgetStore.sync(incoming)
        if artMissing, incoming.artworkSongId != nil {
            artworkEpoch &+= 1
        }
    }

    private func shouldAccept(_ incoming: WatchPlaybackPayload) -> Bool {
        if payload.updatedAt == 0 { return true }
        if incoming.updatedAt > payload.updatedAt { return true }

        guard let inNP = incoming.nowPlaying, let curNP = payload.nowPlaying else {
            return incoming.updatedAt >= payload.updatedAt
        }
        if inNP.songId != curNP.songId { return true }
        if inNP.isPlaying != curNP.isPlaying { return true }
        return incoming.updatedAt >= payload.updatedAt
    }

    private func applyArtwork(from message: [String: Any]) {
        guard let songId = message[WatchBridgeKey.artworkSongId] as? String,
              let data = Self.jpegData(from: message[WatchBridgeKey.artworkJPEG]),
              !data.isEmpty
        else { return }
        WatchArtStore.saveArtwork(data, songId: songId)
        WatchWidgetStore.saveArtwork(data, songId: songId)
        WatchWidgetStore.reloadTimelines()
        artworkEpoch &+= 1
    }

    private func applyOptimistic(_ command: WatchCommand) {
        guard var np = payload.nowPlaying else { return }
        switch command {
        case .togglePlay:
            np.isPlaying.toggle()
        case .next, .previous:
            return
        default:
            return
        }
        np.capturedAt = Date().timeIntervalSince1970
        np.elapsed = np.elapsed(at: Date())
        var updated = payload
        updated.nowPlaying = np
        updated.updatedAt = Date().timeIntervalSince1970
        payload = updated
        WatchWidgetStore.sync(updated)
    }

    private static func jpegData(from value: Any?) -> Data? {
        if let data = value as? Data { return data }
        if let data = value as? NSData { return data as Data }
        return nil
    }

    private func refreshConnectionState(_ session: WCSession) {
        isActivated = session.activationState == .activated
        isPhoneConnected = isActivated && session.isCompanionAppInstalled
        isReachable = session.isReachable
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            if let error {
                WatchSessionStore.shared.lastSyncError = error.localizedDescription
            }
            WatchSessionStore.shared.refreshConnectionState(session)
            WatchSessionStore.shared.ingest(session.receivedApplicationContext)
            WatchSessionStore.shared.flushPending()
            if WatchSessionStore.shared.payload.updatedAt == 0 {
                WatchSessionStore.shared.requestSync()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            WatchSessionStore.shared.refreshConnectionState(session)
            if session.isReachable {
                WatchSessionStore.shared.ingest(session.receivedApplicationContext)
                WatchSessionStore.shared.requestSync()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            WatchSessionStore.shared.ingest(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        DispatchQueue.main.async {
            WatchSessionStore.shared.ingest(message)
            replyHandler(["ok": true])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            WatchSessionStore.shared.ingest(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        DispatchQueue.main.async {
            if userInfo[WatchBridgeKey.command] != nil { return }
            WatchSessionStore.shared.ingest(userInfo)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let songId = file.metadata?[WatchBridgeKey.artworkSongId] as? String,
              let data = try? Data(contentsOf: file.fileURL)
        else { return }
        WatchArtStore.saveArtwork(data, songId: songId)
        WatchWidgetStore.saveArtwork(data, songId: songId)
        WatchWidgetStore.reloadTimelines()
        DispatchQueue.main.async {
            WatchSessionStore.shared.artworkEpoch &+= 1
        }
    }
}
