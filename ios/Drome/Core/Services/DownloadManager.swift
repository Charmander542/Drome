import Foundation

/// Manages offline downloads of original (lossless) files via a background
/// URLSession, so queued albums keep downloading when the app is suspended.
/// Files land under Application Support/Drome/Downloads/<server>/ and the
/// player transparently prefers them over streaming.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var downloadedIDs: Set<String> = []

    private let client: SubsonicClient
    private let database: AppDatabase
    private let serverKey: String
    private var session: URLSession!
    private let sessionDelegate = DownloadSessionDelegate()
    private var tasksBySongID: [String: URLSessionDownloadTask] = [:]

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
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    static func directory(for serverKey: String) -> URL {
        let safe = serverKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Drome/Downloads/\(safe)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func reload() {
        records = (try? database.downloadRecords(serverKey: serverKey)) ?? []
        downloadedIDs = Set(records.filter { $0.state == "done" }.map(\.songId))
    }

    // MARK: - Queries

    func localURL(songId: String) -> URL? {
        guard downloadedIDs.contains(songId),
              let record = records.first(where: { $0.songId == songId }),
              let relPath = record.relPath else { return nil }
        let url = Self.directory(for: serverKey).appendingPathComponent(relPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isDownloaded(_ songId: String) -> Bool {
        downloadedIDs.contains(songId)
    }

    func isBusy(_ songId: String) -> Bool {
        progress[songId] != nil
    }

    var totalBytesUsed: Int64 {
        records.filter { $0.state == "done" }.reduce(0) { $0 + $1.fileSize }
    }

    /// Songs that are downloaded, decoded from stored metadata (for offline
    /// browsing and the storage screen).
    func downloadedSongs() -> [Song] {
        records
            .filter { $0.state == "done" }
            .compactMap { try? JSONDecoder().decode(Song.self, from: Data($0.songJSON.utf8)) }
    }

    // MARK: - Enqueue / cancel / remove

    func download(_ songs: [Song], albumId: String? = nil, albumName: String? = nil,
                  artist: String? = nil) {
        for song in songs {
            guard !downloadedIDs.contains(song.id), progress[song.id] == nil else { continue }
            guard let url = client.downloadURL(songId: song.id) else { continue }
            let json = (try? JSONEncoder().encode(song)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let record = DownloadRecord(
                serverKey: serverKey, songId: song.id, songJSON: json,
                albumId: albumId ?? song.albumId ?? "",
                albumName: albumName ?? song.album ?? "",
                artist: artist ?? song.artist ?? "",
                state: "downloading", relPath: nil, fileSize: 0)
            try? database.upsertDownload(record)

            let task = session.downloadTask(with: url)
            task.taskDescription = song.id
            tasksBySongID[song.id] = task
            progress[song.id] = 0
            task.resume()
        }
        reload()
    }

    func cancel(songId: String) {
        tasksBySongID[songId]?.cancel()
        tasksBySongID[songId] = nil
        progress[songId] = nil
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
        reload()
    }

    // MARK: - Delegate callbacks (hopped onto the main actor)

    fileprivate func handleProgress(songId: String, fraction: Double) {
        progress[songId] = fraction
    }

    fileprivate func handleFinished(songId: String, relPath: String, fileSize: Int64) {
        progress[songId] = nil
        tasksBySongID[songId] = nil
        try? database.setDownloadState(serverKey: serverKey, songId: songId,
                                       state: "done", relPath: relPath, fileSize: fileSize)
        reload()
    }

    fileprivate func handleFailed(songId: String) {
        progress[songId] = nil
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
                manager?.handleFinished(songId: songId, relPath: relPath, fileSize: size ?? 0)
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
            AppDelegate.backgroundSessionCompletionHandler?()
            AppDelegate.backgroundSessionCompletionHandler = nil
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
