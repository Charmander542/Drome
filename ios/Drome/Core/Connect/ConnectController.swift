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
                    snapshot: snap))
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
        do {
            if let session = try await client.getSession(), let snap = session.snapshot {
                applyingRemote = true
                defer { applyingRemote = false }
                player.clearRemotePlayheadMirror()
                lastMirroredSongId = nil
                player.applyConnectSnapshot(snap, startPlaying: true)
            }
            _ = try await client.postCommand(ConnectCommandPost(
                type: ConnectCommandType.takeControl,
                fromDeviceId: deviceId,
                targetDeviceId: deviceId,
                seekTo: nil))
            isRemote = false
            ignoreRemoteUntil = Date().addingTimeInterval(4)
            notice = "Playing here"
            await publishSession(force: true)
            await refreshDevices()
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
        // Another device owns Connect playback — ask before taking over.
        let otherOwns: Bool = {
            if let active = remoteSession?.activeDeviceId, active != deviceId {
                return true
            }
            // Session row can briefly lag while we still know we're remote.
            return isRemote
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
        isRemote = false
        ignoreRemoteUntil = Date().addingTimeInterval(4)
        player?.clearRemotePlayheadMirror()
        lastMirroredSongId = nil
        action?()
        notice = "Playing here"
        Task {
            await publishSession(force: true)
            await refreshDevices()
        }
    }

    func declineSwitchPrompt() {
        showSwitchPrompt = false
        pendingLocalPlayback = nil
    }

    private func tick() async {
        await heartbeat()
        await refreshDevices()
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
        do {
            _ = try await client.putDevice(body)
            if serverStatus != nil { serverStatus = nil }
        } catch {
            serverStatus = error.localizedDescription
        }
    }

    private func refreshDevices() async {
        do {
            devices = try await client.listDevices()
            if serverStatus != nil { serverStatus = nil }
        } catch {
            serverStatus = error.localizedDescription
        }
        if let session = try? await client.getSession() {
            remoteSession = session
        }
    }

    private func syncRemoteMode() {
        if let until = ignoreRemoteUntil, Date() < until {
            isRemote = false
            return
        }
        ignoreRemoteUntil = nil

        guard let session = remoteSession else {
            isRemote = false
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
            isRemote = false
        } else if devices.contains(where: { $0.id == active }) {
            isRemote = true
            if player?.isPlaying == true {
                player?.pause()
            }
            mirrorRemoteSnapshotIfNeeded(session)
        } else {
            // Active device went offline — stay put, don't steal.
            isRemote = false
            player?.clearRemotePlayheadMirror()
        }
    }

    /// Keep local queue / Now Playing in sync with the active device without starting audio.
    private func mirrorRemoteSnapshotIfNeeded(_ session: ConnectSession) {
        guard let player, let snap = session.snapshot else { return }
        let songId = snap.currentSong.id
        if songId != lastMirroredSongId || player.current?.song.id != songId {
            lastMirroredSongId = songId
            applyingRemote = true
            defer { applyingRemote = false }
            player.applyConnectSnapshot(snap, startPlaying: false, recordPlay: false)
        }
        player.mirrorRemotePlayhead(
            elapsed: snap.elapsed,
            duration: snap.currentSong.duration.map(TimeInterval.init) ?? player.duration,
            isPlaying: session.isPlaying)
    }

    private func publishSession(force: Bool) async {
        // Never claim activeDeviceId while another device owns playback.
        guard !applyingRemote, !isRemote, let player, let snap = player.connectSnapshot() else { return }
        let fingerprint = "\(snap.currentSong.id)|\(Int(snap.elapsed))|\(player.isPlaying)|\(snap.userQueue.count)|\(snap.contextQueue.count)"
        if !force, fingerprint == lastPublishedFingerprint { return }
        lastPublishedFingerprint = fingerprint
        if let session = try? await client.putSession(ConnectSessionPut(
            activeDeviceId: deviceId,
            isPlaying: player.isPlaying,
            snapshot: snap)) {
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
            if let session = try? await client.getSession(), let snap = session.snapshot {
                applyingRemote = true
                defer { applyingRemote = false }
                player.clearRemotePlayheadMirror()
                lastMirroredSongId = nil
                player.applyConnectSnapshot(snap, startPlaying: true)
                isRemote = false
                ignoreRemoteUntil = Date().addingTimeInterval(4)
                notice = "Playing here"
                await publishSession(force: true)
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
}
