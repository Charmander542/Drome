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
    @Published var notice: String?

    let deviceId: String
    let deviceName: String

    private let client: DromeConnectClient
    private weak var player: PlayerEngine?
    private var loopTask: Task<Void, Never>?
    private var lastCommandAt: Double = 0
    private var lastPublishedFingerprint: String?
    private var applyingRemote = false

    init(client: DromeConnectClient, player: PlayerEngine) {
        self.client = client
        self.player = player
        self.deviceId = Self.stableDeviceId()
        self.deviceName = Self.defaultDeviceName()
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

    func transfer(to device: ConnectDevice) async {
        guard let player, device.id != deviceId else { return }
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
            notice = "Playing on \(device.name)"
            await refreshDevices()
        } catch {
            notice = error.localizedDescription
        }
    }

    func takeControl() async {
        guard let player else { return }
        do {
            if let session = try await client.getSession(), let snap = session.snapshot {
                applyingRemote = true
                defer { applyingRemote = false }
                player.applyConnectSnapshot(snap, startPlaying: true)
            }
            _ = try await client.postCommand(ConnectCommandPost(
                type: ConnectCommandType.takeControl,
                fromDeviceId: deviceId,
                targetDeviceId: deviceId,
                seekTo: nil))
            isRemote = false
            notice = "Playing here"
            await publishSession(force: true)
            await refreshDevices()
        } catch {
            notice = error.localizedDescription
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
        guard let session = remoteSession else {
            isRemote = false
            return
        }
        let active = session.activeDeviceId
        if active == deviceId {
            isRemote = false
        } else if devices.contains(where: { $0.id == active }) {
            isRemote = true
            if player?.isPlaying == true {
                player?.pause()
            }
        }
    }

    private func publishSession(force: Bool) async {
        guard !applyingRemote, let player, let snap = player.connectSnapshot() else { return }
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
                player.applyConnectSnapshot(snap, startPlaying: true)
                isRemote = false
                notice = "Playing here"
                await publishSession(force: true)
            }
        case ConnectCommandType.play:
            player.resume()
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
