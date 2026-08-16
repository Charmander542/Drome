import Foundation
import UIKit

/// Live download fractions — separate from `DownloadManager` so list rows that
/// only care about "is downloaded?" aren't invalidated on every progress tick.
@MainActor
final class DownloadProgressStore: ObservableObject {
    @Published private(set) var values: [String: Double] = [:]

    func set(_ songId: String, fraction: Double) {
        values[songId] = fraction
    }

    func remove(_ songId: String) {
        values[songId] = nil
    }

    func contains(_ songId: String) -> Bool {
        values[songId] != nil
    }
}

/// Manages offline downloads of original (lossless) files via a background
/// URLSession, so queued albums keep downloading when the app is suspended.
/// Files land under Application Support/Drome/Downloads/<server>/ and the
/// player transparently prefers them over streaming.
@MainActor
final class DownloadManager: ObservableObject {
    /// Observed only by in-progress download UI (not SongRow lists).
    let liveProgress = DownloadProgressStore()
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var downloadedIDs: Set<String> = []
    @Published private(set) var playlistMemberships: [DownloadPlaylistMembership] = []
    /// playlistId → count of memberships that are locally downloaded.
    private var downloadedCountByPlaylist: [String: Int] = [:]
    /// Decoded metadata for finished downloads; rebuilt in `reload()`.
    private(set) var doneSongsById: [String: Song] = [:]
    /// Bumps when a local cover file is written so list art can refresh offline.
    @Published private(set) var coverRevision: UInt64 = 0

    private let client: SubsonicClient
    private let database: AppDatabase
    private let serverKey: String
    private var session: URLSession!
    private let sessionDelegate = DownloadSessionDelegate()
    private var tasksBySongID: [String: URLSessionDownloadTask] = [:]
    private var coverInflight: Set<String> = []

    init(client: SubsonicClient, database: AppDatabase, serverKey: String) {
        self.client = client
        self.database = database
        self.serverKey = serverKey

        sessionDelegate.manager = self
        sessionDelegate.trustedHost = client.account.allowSelfSigned ? client.account.serverURL.host : nil
        sessionDelegate.destinationDirectory = Self.directory(for: serverKey)

        let config = URLSessionConfiguration.background(
            withIdentifier: "com.drome.app.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)

        try? FileManager.default.createDirectory(at: artDirectory, withIntermediateDirectories: true)

        reload()
        // Reattach to tasks that survived an app relaunch.
        session.getAllTasks { tasks in
            Task { @MainActor [weak self] in
                for task in tasks {
                    guard let songId = task.taskDescription else { continue }
                    self?.tasksBySongID[songId] = task as? URLSessionDownloadTask
                }
            }
        }
        Task { await self.backfillMissingCoverArt() }
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    static func directory(for serverKey: String) -> URL {
        let safe = serverKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        #if os(tvOS)
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        let dir = root.appendingPathComponent("Drome/Downloads/\(safe)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var artDirectory: URL {
        Self.directory(for: serverKey).appendingPathComponent("Art", isDirectory: true)
    }

    private func reload() {
        let key = serverKey
        let db = database
        let loadedRecords = (try? db.downloadRecords(serverKey: key)) ?? []
        let memberships = (try? db.downloadPlaylistMemberships(serverKey: key)) ?? []
        records = loadedRecords
        downloadedIDs = Set(loadedRecords.filter { $0.state == "done" }.map(\.songId))
        playlistMemberships = memberships
        rebuildPlaylistDownloadCounts()

        // JSON-decoding every finished download on the main actor freezes first paint.
        let doneJSON = loadedRecords.compactMap { record -> (String, String)? in
            guard record.state == "done" else { return nil }
            return (record.songId, record.songJSON)
        }
        Task(priority: .utility) { [weak self] in
            let decoded = await Task.detached(priority: .utility) {
                let decoder = JSONDecoder()
                var map: [String: Song] = [:]
                map.reserveCapacity(doneJSON.count)
                for (id, json) in doneJSON {
                    if let song = try? decoder.decode(Song.self, from: Data(json.utf8)) {
                        map[id] = song
                    }
                }
                return map
            }.value
            self?.doneSongsById = decoded
        }
    }

    private func rebuildPlaylistDownloadCounts() {
        var counts: [String: Int] = [:]
        for row in playlistMemberships where downloadedIDs.contains(row.songId) {
            counts[row.playlistId, default: 0] += 1
        }
        downloadedCountByPlaylist = counts
    }

    // MARK: - Queries

    func localURL(songId: String) -> URL? {
        guard downloadedIDs.contains(songId),
              let record = records.first(where: { $0.songId == songId }),
              let relPath = record.relPath else { return nil }
        let url = Self.directory(for: serverKey).appendingPathComponent(relPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Local album art for a cover id (shared across songs on the same album).
    func localCoverURL(coverId: String?) -> URL? {
        guard let coverId, !coverId.isEmpty else { return nil }
        let base = Self.safeFileComponent(coverId)
        let dir = artDirectory
        for ext in ["jpg", "jpeg", "png", "webp"] {
            let url = dir.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func localCoverURL(for song: Song) -> URL? {
        localCoverURL(coverId: song.coverArt ?? song.albumId ?? song.id)
    }

    func isDownloaded(_ songId: String) -> Bool {
        downloadedIDs.contains(songId)
    }

    var downloadedCount: Int { downloadedIDs.count }

    /// True when every song id is present in the local download set.
    func isPlaylistFullyDownloaded(songIds: [String]) -> Bool {
        !songIds.isEmpty && songIds.allSatisfy { downloadedIDs.contains($0) }
    }

    /// Best-effort list-row check using precomputed membership counts.
    func isPlaylistFullyDownloaded(playlistId: String, expectedCount: Int) -> Bool {
        guard expectedCount > 0 else { return false }
        return (downloadedCountByPlaylist[playlistId] ?? 0) >= expectedCount
    }

    func isBusy(_ songId: String) -> Bool {
        liveProgress.contains(songId)
    }

    /// Snapshot for UIs that still expect a dictionary (prefer `liveProgress`).
    var progress: [String: Double] { liveProgress.values }

    var totalBytesUsed: Int64 {
        records.filter { $0.state == "done" }.reduce(0) { $0 + $1.fileSize }
    }

    /// Songs that are downloaded, decoded from stored metadata (for offline
    /// browsing and the storage screen).
    func downloadedSongs() -> [Song] {
        Array(doneSongsById.values)
    }

    func song(forDownloadedId songId: String) -> Song? {
        doneSongsById[songId]
    }

    // MARK: - Enqueue / cancel / remove

    func download(_ songs: [Song], albumId: String? = nil, albumName: String? = nil,
                  artist: String? = nil, playlistId: String? = nil, playlistName: String? = nil) {
        Task { await enqueueDownloads(songs, albumId: albumId, albumName: albumName,
                                      artist: artist, playlistId: playlistId, playlistName: playlistName) }
    }

    /// Resolves each song from Navidrome before enqueue so offline metadata
    /// always comes from the library (never a stale/Spotify-shaped snapshot).
    private func enqueueDownloads(_ songs: [Song], albumId: String?, albumName: String?,
                                  artist: String?, playlistId: String?, playlistName: String?) async {
        for song in songs {
            // Already offline: attach playlist membership without re-fetching bytes.
            if downloadedIDs.contains(song.id) {
                attachPlaylistMembership(songId: song.id, playlistId: playlistId, playlistName: playlistName)
                continue
            }
            if !liveProgress.contains(song.id) {
                guard let url = client.downloadURL(songId: song.id) else { continue }
                let resolved = (try? await client.song(id: song.id)) ?? song
                guard !resolved.id.isEmpty else { continue }
                let json = (try? JSONEncoder().encode(resolved)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let record = DownloadRecord(
                    serverKey: serverKey, songId: resolved.id, songJSON: json,
                    albumId: albumId ?? resolved.albumId ?? "",
                    albumName: albumName ?? resolved.album ?? "",
                    artist: artist ?? resolved.artist ?? "",
                    state: "downloading", relPath: nil, fileSize: 0)
                try? database.upsertDownload(record)

                let task = session.downloadTask(with: url)
                task.taskDescription = resolved.id
                tasksBySongID[resolved.id] = task
                liveProgress.set(resolved.id, fraction: 0)
                task.resume()
            }
            attachPlaylistMembership(songId: song.id, playlistId: playlistId, playlistName: playlistName)
        }
        reload()
    }

    private func attachPlaylistMembership(songId: String, playlistId: String?, playlistName: String?) {
        guard let playlistId, !playlistId.isEmpty else { return }
        let membership = DownloadPlaylistMembership(
            serverKey: serverKey, songId: songId,
            playlistId: playlistId, playlistName: playlistName ?? "")
        try? database.upsertDownloadPlaylistMembership(membership)
    }

    func cancel(songId: String) {
        tasksBySongID[songId]?.cancel()
        tasksBySongID[songId] = nil
        liveProgress.remove(songId)
        try? database.deleteDownload(serverKey: serverKey, songId: songId)
        reload()
    }

    func remove(songId: String) {
        if let url = localURL(songId: songId) {
            try? FileManager.default.removeItem(at: url)
        }
        try? database.deleteDownload(serverKey: serverKey, songId: songId)
        reload()
    }

    func removeAll() {
        for record in records where record.state == "done" {
            if let relPath = record.relPath {
                let url = Self.directory(for: serverKey).appendingPathComponent(relPath)
                try? FileManager.default.removeItem(at: url)
            }
            try? database.deleteDownload(serverKey: serverKey, songId: record.songId)
        }
        try? FileManager.default.removeItem(at: artDirectory)
        try? FileManager.default.createDirectory(at: artDirectory, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Cover art

    func ensureCoverArt(for song: Song) {
        let coverId = song.coverArt ?? song.albumId ?? song.id
        Task { await downloadCoverIfNeeded(coverId: coverId) }
    }

    private func backfillMissingCoverArt() async {
        let songs = Array(doneSongsById.values)
        for song in songs {
            let coverId = song.coverArt ?? song.albumId ?? song.id
            await downloadCoverIfNeeded(coverId: coverId)
        }
    }

    private func downloadCoverIfNeeded(coverId: String) async {
        guard !coverId.isEmpty else { return }
        if localCoverURL(coverId: coverId) != nil { return }
        guard !coverInflight.contains(coverId) else { return }
        coverInflight.insert(coverId)
        defer { coverInflight.remove(coverId) }

        guard let url = client.coverArtURL(id: coverId, size: 800) else { return }
        // Use the API session so self-signed servers work; keep this off the
        // background download session (audio files only).
        guard let (data, response) = try? await client.session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              !data.isEmpty
        else { return }

        let ext = Self.imageExtension(for: response, data: data)
        let dest = artDirectory.appendingPathComponent("\(Self.safeFileComponent(coverId)).\(ext)")
        do {
            try FileManager.default.createDirectory(at: artDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try data.write(to: dest, options: .atomic)
            // Seed memory cache so offline rows paint without another decode wait.
            if let image = UIImage(data: data) {
                ImageLoader.shared.cacheImage(image, for: dest)
            }
            coverRevision &+= 1
        } catch {
            // Non-fatal — audio download still succeeded.
        }
    }

    private static func safeFileComponent(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
    }

    private static func imageExtension(for response: URLResponse, data: Data) -> String {
        let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if mime.contains("png") { return "png" }
        if mime.contains("webp") { return "webp" }
        if mime.contains("jpeg") || mime.contains("jpg") { return "jpg" }
        // Sniff magic bytes.
        if data.count >= 8 {
            let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if data.prefix(4).elementsEqual(png) { return "png" }
        }
        return "jpg"
    }

    // MARK: - Delegate callbacks (hopped onto the main actor)

    fileprivate func handleProgress(songId: String, fraction: Double) {
        let previous = liveProgress.values[songId] ?? -1
        // Coalesce tiny progress ticks so the Downloads screen stays calm.
        if fraction < 0.999, abs(fraction - previous) < 0.05 { return }
        liveProgress.set(songId, fraction: fraction)
    }

    fileprivate func handleFinished(songId: String, relPath: String, fileSize: Int64) {
        liveProgress.remove(songId)
        tasksBySongID[songId] = nil
        try? database.setDownloadState(serverKey: serverKey, songId: songId,
                                       state: "done", relPath: relPath, fileSize: fileSize)
        reload()
        if let song = doneSongsById[songId] {
            ensureCoverArt(for: song)
        }
    }

    fileprivate func handleFailed(songId: String) {
        liveProgress.remove(songId)
        tasksBySongID[songId] = nil
        try? database.setDownloadState(serverKey: serverKey, songId: songId, state: "failed")
        reload()
    }
}

/// Plain NSObject delegate for the background session. File moves happen
/// synchronously on the session queue (required — the temp file disappears
/// once the callback returns); state updates hop to the main actor.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    weak var manager: DownloadManager?
    var trustedHost: String?
    var destinationDirectory: URL?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let songId = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak manager] in
            manager?.handleProgress(songId: songId, fraction: fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let songId = downloadTask.taskDescription,
              let directory = destinationDirectory else { return }

        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            Task { @MainActor [weak manager] in manager?.handleFailed(songId: songId) }
            return
        }

        let suggested = downloadTask.response?.suggestedFilename ?? ""
        let ext = (suggested as NSString).pathExtension.isEmpty ? "flac" : (suggested as NSString).pathExtension
        let safeID = songId.replacingOccurrences(of: "/", with: "_")
        let relPath = "\(safeID).\(ext)"
        let destination = directory.appendingPathComponent(relPath)

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            Task { @MainActor [weak manager] in
                manager?.handleFinished(songId: songId, relPath: relPath, fileSize: size)
            }
        } catch {
            Task { @MainActor [weak manager] in manager?.handleFailed(songId: songId) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled,
              let songId = task.taskDescription else { return }
        Task { @MainActor [weak manager] in
            manager?.handleFailed(songId: songId)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            #if os(iOS)
            AppDelegate.backgroundSessionCompletionHandler?()
            AppDelegate.backgroundSessionCompletionHandler = nil
            #endif
        }
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trustedHost,
           challenge.protectionSpace.host.caseInsensitiveCompare(trustedHost) == .orderedSame,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
