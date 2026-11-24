import Foundation
import UIKit
import Combine

/// Owns presence, session publish, command poll, and transfer for this device.
@MainActor
final class ConnectController: ObservableObject {
    @Published private(set) var devices: [ConnectDevice] = []
    @Published private(set) var remoteSession: ConnectSession?
    /// True when another device is active and this one should not play audio.
    @Published private(set) var isRemote: Bool = false
    @Published private(set) var serverStatus: String?
    /// Optional rebuild tip; omitted for auth / unreachable-host failures.
    @Published private(set) var serverHelpCaption: String?
    /// Device id currently being transferred to / taking control on (shows spinner in picker).
    @Published private(set) var busyDeviceId: String?
    @Published var notice: String?
    /// Ask before stealing the active player when the user starts playback here.
    @Published var showSwitchPrompt = false
    @Published private(set) var switchPromptDeviceName = ""

    let deviceId: String
    let deviceName: String

    private let client: DromeConnectClient
    private weak var player: PlayerEngine?
    private var loopTask: Task<Void, Never>?
    private var lastCommandAt: Double = 0
    private var lastPublishedFingerprint: String?
    private var applyingRemote = false
    private var pendingLocalPlayback: (() -> Void)?
    private var lastMirroredSongId: String?
    /// Briefly ignore remote-active pauses after the user confirms "play here".
    private var ignoreRemoteUntil: Date?
    private var lastHeartbeatAt = Date.distantPast
    private var lastHeartbeatSignature: String?
    private var lastSessionFetchAt = Date.distantPast

    /// With no other device online nobody is mirroring this playhead, so the
    /// full queue snapshot (hundreds of KB) only needs occasional refreshes
    /// instead of competing with the audio stream every two seconds.
    private static let soloPublishInterval: TimeInterval = 30
    private static let soloSessionRefreshInterval: TimeInterval = 30
    /// Devices drop off the server ~45s after their last heartbeat.
    private static let soloHeartbeatInterval: TimeInterval = 10

    private var othersOnline: Bool {
        devices.contains { $0.id != deviceId }
    }

    var isBusy: Bool { busyDeviceId != nil }

    init(client: DromeConnectClient, player: PlayerEngine) {
        self.client = client
        self.player = player
        self.deviceId = Self.stableDeviceId()
        self.deviceName = Self.defaultDeviceName()
        player.localPlaybackGate = { [weak self] action in
            guard let self else {
                action()
                return true
            }
            return self.requestLocalPlayback(action)
        }
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        Task { try? await client.deleteDevice(id: deviceId) }
    }

    var isActivePlayer: Bool {
        remoteSession?.activeDeviceId == deviceId || (!isRemote && remoteSession == nil)
    }

    /// Transfers playback to another device. Returns `true` on success.
    @discardableResult
    func transfer(to device: ConnectDevice) async -> Bool {
        guard let player, device.id != deviceId, !isBusy else { return false }
        busyDeviceId = device.id
        notice = "Switching to \(device.name)…"
        defer { busyDeviceId = nil }
        do {
            if let snap = player.connectSnapshot() {
                _ = try await client.putSession(ConnectSessionPut(
                    activeDeviceId: device.id,
                    isPlaying: player.isPlaying,
                    snapshot: snap,
                    claim: true))
            }
            _ = try await client.postCommand(ConnectCommandPost(
                type: ConnectCommandType.transfer,
                fromDeviceId: deviceId,
                targetDeviceId: device.id,
                seekTo: nil))
            player.pause()
            isRemote = true
            player.clearRemotePlayheadMirror()
            notice = "Playing on \(device.name)"
            await refreshDevices()
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    /// Pulls playback onto this device. Returns `true` on success.
    @discardableResult
    func takeControl() async -> Bool {
        guard let player, !isBusy else { return false }
        busyDeviceId = deviceId
        notice = "Switching here…"
        defer { busyDeviceId = nil }
        let previousActive = remoteSession?.activeDeviceId
        do {
            if let session = try await client.getSession(), let snap = session.snapshot {
                applyingRemote = true
                defer { applyingRemote = false }
                player.clearRemotePlayheadMirror()
                lastMirroredSongId = nil
                player.applyConnectSnapshot(snap, startPlaying: true, force: true)
            }
            isRemote = false
            ignoreRemoteUntil = Date().addingTimeInterval(8)
            notice = "Playing here"
            await claimActiveAndStopOthers(previousActive: previousActive)
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func sendRemote(_ type: String, seekTo: Double? = nil) async {
        guard let active = remoteSession?.activeDeviceId, active != deviceId else { return }
        do {
            _ = try await client.postCommand(ConnectCommandPost(
                type: type,
                fromDeviceId: deviceId,
                targetDeviceId: active,
                seekTo: seekTo))
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Returns `true` when `action` ran immediately. `false` when deferred behind the switch prompt.
    @discardableResult
    func requestLocalPlayback(_ action: @escaping () -> Void) -> Bool {
        // Mid-confirm / post-"Play here" window — always allow local start.
        // Without this, confirm → play() → gate sees the other device still
        // active and re-opens the prompt (Play here appears broken).
        if let until = ignoreRemoteUntil, Date() < until {
            action()
            return true
        }

        // Stick to the last active device. Only prompt — never silent steal.
        let otherOwns: Bool = {
            guard let active = remoteSession?.activeDeviceId, !active.isEmpty else {
                return false
            }
            return active != deviceId
        }()
        guard otherOwns else {
            action()
            return true
        }
        pendingLocalPlayback = action
        if let active = remoteSession?.activeDeviceId {
            switchPromptDeviceName = devices.first(where: { $0.id == active })?.name
                ?? "another device"
        } else if switchPromptDeviceName.isEmpty {
            switchPromptDeviceName = "another device"
        }
        #if os(iOS)
        let canPresentAlert = UIApplication.shared.connectedScenes.contains {
            ($0 as? UIWindowScene)?.activationState == .foregroundActive
        }
        if !canPresentAlert {
            // CarPlay / background — no alert host; take over so play isn't stuck.
            confirmSwitchToThisDevice()
            return false
        }
        #endif
        showSwitchPrompt = true
        return false
    }

    func confirmSwitchToThisDevice() {
        showSwitchPrompt = false
        let action = pendingLocalPlayback
        pendingLocalPlayback = nil
        let previousActive = remoteSession?.activeDeviceId
        isRemote = false
        // Must be set BEFORE action() so nested play() passes the gate.
        ignoreRemoteUntil = Date().addingTimeInterval(8)
        player?.clearRemotePlayheadMirror()
        lastMirroredSongId = nil
        action?()
        notice = "Playing here"
        Task {
            await claimActiveAndStopOthers(previousActive: previousActive)
        }
    }

    func declineSwitchPrompt() {
        showSwitchPrompt = false
        pendingLocalPlayback = nil
    }

    /// Become the active player and tell the previous one to stop audio.
    private func claimActiveAndStopOthers(previousActive: String?) async {
        await publishSession(force: true, claim: true)
        if let prev = previousActive, prev != deviceId {
            _ = try? await client.postCommand(ConnectCommandPost(
                type: ConnectCommandType.pause,
                fromDeviceId: deviceId,
                targetDeviceId: prev,
                seekTo: nil))
        }
        _ = try? await client.postCommand(ConnectCommandPost(
            type: ConnectCommandType.takeControl,
            fromDeviceId: deviceId,
            targetDeviceId: deviceId,
            seekTo: nil))
        await refreshDevices()
    }

    private func tick() async {
        await heartbeat()
        await refreshDevices(forceSession: false)
        await pullCommands()
        await syncRemoteMode()
        if !isRemote {
            await publishSession(force: false)
        }
    }

    private func heartbeat() async {
        guard let player else { return }
        let song = player.current?.song
        let body = ConnectDeviceHeartbeat(
            id: deviceId,
            name: deviceName,
            platform: ConnectPlatform.current,
            model: UIDevice.current.model,
            isPlaying: player.isPlaying && !isRemote,
            songId: song?.id,
            songTitle: song?.title,
            songArtist: song?.displayArtist,
            elapsed: player.accurateElapsed(),
            duration: player.duration,
            capabilities: ["audio", "remote", "transfer"])
        // Alone: presence only has to outlive the server TTL. Anything another
        // device could show (track, play state) still goes out immediately.
        let signature = "\(body.songId ?? "")|\(body.isPlaying)"
        let now = Date()
        if !othersOnline,
           serverStatus == nil,
           signature == lastHeartbeatSignature,
           now.timeIntervalSince(lastHeartbeatAt) < Self.soloHeartbeatInterval {
            return
        }
        do {
            _ = try await client.putDevice(body)
            lastHeartbeatAt = now
            lastHeartbeatSignature = signature
            clearServerStatus()
        } catch {
            recordServerFailure(error)
        }
    }

    private func refreshDevices(forceSession: Bool = true) async {
        do {
            let listed = try await client.listDevices()
            if listed != devices { devices = listed }
            clearServerStatus()
        } catch {
            recordServerFailure(error)
        }
        guard forceSession || sessionNeedsRefresh() else { return }
        if let session = try? await client.getSession() {
            lastSessionFetchAt = Date()
            adoptSession(session)
        }
    }

    /// The (small) device list already says who is active, so the full
    /// session — queue snapshot included — is only downloaded when another
    /// device is the player and we mirror it, or ownership looks like it moved.
    /// While this device is the active player the server copy is just what
    /// we published; a slow refresh is enough as a safety net.
    private func sessionNeedsRefresh() -> Bool {
        guard let session = remoteSession else { return true }
        if let listedActive = devices.first(where: { $0.isActive == true })?.id {
            if listedActive != deviceId || session.activeDeviceId != deviceId { return true }
        } else if othersOnline {
            return true
        }
        return Date().timeIntervalSince(lastSessionFetchAt) >= Self.soloSessionRefreshInterval
    }

    /// Publish only when the server copy actually moved (it restamps
    /// `updatedAt` on every write), so idle polls don't invalidate observers.
    private func adoptSession(_ session: ConnectSession) {
        if let existing = remoteSession,
           existing.updatedAt == session.updatedAt,
           existing.activeDeviceId == session.activeDeviceId,
           existing.isPlaying == session.isPlaying,
           (existing.snapshot == nil) == (session.snapshot == nil) {
            return
        }
        remoteSession = session
    }

    private func setRemote(_ value: Bool) {
        if isRemote != value { isRemote = value }
    }

    private func syncRemoteMode() {
        if let until = ignoreRemoteUntil, Date() < until {
            setRemote(false)
            return
        }
        ignoreRemoteUntil = nil

        guard let session = remoteSession,
              !session.activeDeviceId.isEmpty else {
            setRemote(false)
            player?.clearRemotePlayheadMirror()
            lastMirroredSongId = nil
            return
        }
        let active = session.activeDeviceId
        if active == deviceId {
            if isRemote {
                player?.clearRemotePlayheadMirror()
                lastMirroredSongId = nil
            }
            setRemote(false)
            return
        }

        // Another device is the active player — this one must not make sound.
        setRemote(true)
        if player?.isLocalPlaybackEngaged == true {
            player?.pause()
        }
        mirrorRemoteSnapshotIfNeeded(session)
    }

    /// Keep local queue / Now Playing in sync with the active device without starting audio.
    private func mirrorRemoteSnapshotIfNeeded(_ session: ConnectSession) {
        guard let player, let snap = session.snapshot else { return }
        let songId = snap.currentSong.id
        if songId != lastMirroredSongId || player.current?.song.id != songId {
            lastMirroredSongId = songId
            applyingRemote = true
            defer { applyingRemote = false }
            // force: false — skip if mid track-advance to avoid crashes; playhead
            // still mirrors below so UI stays in sync.
            player.applyConnectSnapshot(snap, startPlaying: false, recordPlay: false)
        }
        player.mirrorRemotePlayhead(
            elapsed: snap.elapsed,
            duration: snap.currentSong.duration.map(TimeInterval.init) ?? player.duration,
            isPlaying: session.isPlaying)
    }

    private func publishSession(force: Bool, claim: Bool = false) async {
        // Only the active player may refresh the shared session. Claiming a new
        // activeDeviceId requires `claim: true` (confirm / takeControl / transfer).
        guard !applyingRemote, !isRemote, let player, let current = player.current else { return }
        if !claim, let active = remoteSession?.activeDeviceId, !active.isEmpty, active != deviceId {
            return
        }
        // Fingerprint from live state first — building the snapshot copies
        // the whole queue, which is wasted work when nothing will be sent.
        let mirrored = othersOnline
        let elapsed = player.accurateElapsed()
        let elapsedBucket = mirrored
            ? Int(elapsed)
            : Int(elapsed / Self.soloPublishInterval)
        let fingerprint = "\(current.song.id)|\(elapsedBucket)|\(player.isPlaying)|\(player.userQueue.count)|\(player.contextQueue.count)|\(mirrored)"
        if !force, fingerprint == lastPublishedFingerprint { return }
        guard let snap = player.connectSnapshot() else { return }
        lastPublishedFingerprint = fingerprint
        let creating = remoteSession == nil || remoteSession?.activeDeviceId.isEmpty == true
        if let session = try? await client.putSession(ConnectSessionPut(
            activeDeviceId: deviceId,
            isPlaying: player.isPlaying,
            snapshot: snap,
            claim: claim || creating)) {
            lastSessionFetchAt = Date()
            remoteSession = session
        }
    }

    private func pullCommands() async {
        guard let cmds = try? await client.listCommands(deviceId: deviceId, after: lastCommandAt),
              !cmds.isEmpty else { return }
        var acked: [String] = []
        for cmd in cmds {
            lastCommandAt = max(lastCommandAt, cmd.createdAt)
            await apply(cmd)
            acked.append(cmd.id)
        }
        try? await client.ackCommands(ids: acked)
    }

    private func apply(_ cmd: ConnectCommand) async {
        guard let player else { return }
        switch cmd.type {
        case ConnectCommandType.transfer, ConnectCommandType.takeControl:
            // Ignore echoes of a takeover we just initiated locally.
            if let until = ignoreRemoteUntil, Date() < until {
                break
            }
            if let session = try? await client.getSession(), let snap = session.snapshot {
                applyingRemote = true
                defer { applyingRemote = false }
                player.clearRemotePlayheadMirror()
                lastMirroredSongId = nil
                player.applyConnectSnapshot(snap, startPlaying: true, force: true)
                isRemote = false
                ignoreRemoteUntil = Date().addingTimeInterval(8)
                notice = "Playing here"
                await publishSession(force: true, claim: true)
            }
        case ConnectCommandType.play:
            player.resume(bypassConnectGate: true)
        case ConnectCommandType.pause:
            player.pause()
        case ConnectCommandType.next:
            player.next()
        case ConnectCommandType.previous:
            player.previous()
        case ConnectCommandType.seek:
            if let t = cmd.seekTo { player.seek(to: t) }
        default:
            break
        }
    }

    private static func stableDeviceId() -> String {
        let key = "drome.connect.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static func defaultDeviceName() -> String {
        #if os(tvOS)
        return UIDevice.current.name.isEmpty ? "Apple TV" : UIDevice.current.name
        #else
        let name = UIDevice.current.name
        return name.isEmpty ? "iPhone" : name
        #endif
    }

    private func clearServerStatus() {
        if serverStatus != nil { serverStatus = nil }
        if serverHelpCaption != nil { serverHelpCaption = nil }
    }

    private func recordServerFailure(_ error: Error) {
        serverStatus = CompanionNetworkError.shortReason(for: error)
        serverHelpCaption = CompanionNetworkError.connectHelpCaption(for: error)
    }
}
