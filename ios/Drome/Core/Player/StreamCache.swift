import Foundation

/// On-device MP3 cache for resilient streaming over Tailscale / cellular.
///
/// AVPlayer HTTP streams die when the phone hops Wi‑Fi ↔ LTE or Tailscale
/// briefly drops. Caching a complete (or nearly complete) compressed file and
/// playing from disk survives those blips — the same idea as the Apple TV
/// cache, tuned for the phone's "listening away from home" path.
@MainActor
final class StreamCache {
    private let client: SubsonicClient
    private let directory: URL
    private var inflight: [String: Task<URL, Error>] = [:]
    private var lastPrefetchIDs: [String] = []

    /// Max files kept on disk.
    private let maxFiles = 24
    /// Soft cap (~400 MB of 256–320 kbps MP3 ≈ several hours).
    private let maxBytes = 400_000_000

    init(client: SubsonicClient) {
        self.client = client
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("DromeStreamCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Ready-to-play local file, if the cached MP3 looks complete enough.
    func cachedURL(for songID: String, minimumBytes: Int = 48_000) -> URL? {
        let url = destination(for: songID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Tiny / stub files play ~1s then fail — reject them so the player
        // falls back to HTTP instead of thrashing on the same corpse.
        guard size >= minimumBytes else {
            if size > 0 {
                DromeDiagnostics.logNetwork(
                    "streamCache reject \(songID) bytes=\(size) min=\(minimumBytes)")
            }
            return nil
        }
        // Playing from cache must refresh mtime — otherwise trim() can delete
        // an in-use file under prefetch pressure.
        touch(url)
        return url
    }

    /// Download (or return cached) compressed MP3 for `song`.
    func fileURL(for song: Song, maxBitRate: Int) async throws -> URL {
        if let cached = cachedURL(for: song.id) {
            touch(cached)
            return cached
        }
        if let existing = inflight[song.id] {
            return try await existing.value
        }
        let bitRate = maxBitRate
        let task = Task<URL, Error> { [client, directory] in
            try await Self.download(
                song: song,
                client: client,
                directory: directory,
                maxBitRate: bitRate)
        }
        inflight[song.id] = task
        defer { inflight[song.id] = nil }
        let url = try await task.value
        trim()
        DromeDiagnostics.logNetwork(
            "streamCache ready \(song.id) «\(song.title)» bytes=\(fileSize(url))")
        return url
    }

    /// Warm cache for upcoming tracks without blocking playback.
    func prefetch(_ songs: [Song], maxBitRate: Int) {
        let unique = songs.filter { song in
            cachedURL(for: song.id) == nil && inflight[song.id] == nil
        }
        let ids = unique.map(\.id)
        guard ids != lastPrefetchIDs.prefix(ids.count).map({ $0 }) else { return }
        lastPrefetchIDs = ids
        let limit = AudioFXPreferences.prefetchCount
        for song in unique.prefix(limit) {
            Task { [weak self] in
                _ = try? await self?.fileURL(for: song, maxBitRate: maxBitRate)
            }
        }
        if !unique.isEmpty {
            DromeDiagnostics.logNetwork(
                "streamCache prefetch \(unique.prefix(limit).map(\.id).joined(separator: ","))")
        }
    }

    func invalidate(songID: String) {
        let url = destination(for: songID)
        try? FileManager.default.removeItem(at: url)
        inflight[songID]?.cancel()
        inflight[songID] = nil
    }

    // MARK: - Private

    private func destination(for songID: String) -> URL {
        Self.destination(for: songID, in: directory)
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path)
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func trim() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        let ranked = files.compactMap { url -> (URL, Date, Int)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = values?.contentModificationDate else { return nil }
            return (url, date, values?.fileSize ?? 0)
        }
        .sorted { $0.1 > $1.1 }

        var total = ranked.reduce(0) { $0 + $1.2 }
        for (index, entry) in ranked.enumerated() {
            if index < maxFiles && total <= maxBytes { continue }
            total -= entry.2
            try? fm.removeItem(at: entry.0)
        }
    }

    private static func destination(for songID: String, in directory: URL) -> URL {
        let id = songID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("\(id).mp3")
    }

    private static func looksLikeAudio(_ head: Data) -> Bool {
        if head.isEmpty { return false }
        if head.first == 0x3C { return false } // '<' HTML/XML error
        // MP3 frame sync or ID3 tag.
        if head.count >= 3, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 { return true }
        if head.count >= 2, head[0] == 0xFF, (head[1] & 0xE0) == 0xE0 { return true }
        return false
    }

    private static func download(
        song: Song,
        client: SubsonicClient,
        directory: URL,
        maxBitRate: Int
    ) async throws -> URL {
        let dest = destination(for: song.id, in: directory)
        var candidates: [URL] = []
        if let url = client.streamURL(
            songId: song.id, format: "mp3", maxBitRate: maxBitRate,
            estimateContentLength: true) {
            candidates.append(url)
        }
        if maxBitRate != 192,
           let url = client.streamURL(
            songId: song.id, format: "mp3", maxBitRate: 192,
            estimateContentLength: true) {
            candidates.append(url)
        }
        var lastError: Error = URLError(.badURL)
        for remote in candidates {
            do {
                return try await downloadFrom(remote: remote, dest: dest, client: client)
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: dest)
            }
        }
        throw lastError
    }

    private static func downloadFrom(
        remote: URL,
        dest: URL,
        client: SubsonicClient
    ) async throws -> URL {
        let (temp, response) = try await client.session.download(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.badServerResponse)
        }
        let handle = try FileHandle(forReadingFrom: temp)
        let head = try handle.read(upToCount: 32) ?? Data()
        try handle.close()
        guard looksLikeAudio(head) else {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.cannotDecodeContentData)
        }
        let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Reject obviously truncated responses (server error bodies, cut pipes).
        if let http = response as? HTTPURLResponse,
           let expectedStr = http.value(forHTTPHeaderField: "Content-Length"),
           let expected = Int(expectedStr), expected > 64_000,
           size < (expected * 9) / 10 {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.networkConnectionLost)
        }
        guard size >= 48_000 else {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.cannotDecodeContentData)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }
}

/// One upcoming original (lossless) file, downloaded only after the current
/// track is already playing. AVQueuePlayer must not open a second HTTP item —
/// that raced end-of-track and crashed — so the next song is a finished file
/// or it isn't used at all.
@MainActor
final class LosslessAheadCache {
    private let client: SubsonicClient
    private let directory: URL
    private var inflight: [String: Task<URL?, Never>] = [:]
    private let maxFiles = 2
    private let maxBytes = 160_000_000
    /// Skip albums that would saturate a weak link while the current song plays.
    private let maxFileBytes = 80_000_000

    init(client: SubsonicClient) {
        self.client = client
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("DromeLosslessAhead", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cachedURL(for songID: String) -> URL? {
        let url = destination(for: songID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= 48_000 else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Download `song`'s original file. In-flight downloads for other songs
    /// are cancelled so a skip doesn't keep pulling a track we already left.
    func prefetch(_ song: Song) {
        if cachedURL(for: song.id) != nil { return }
        for (id, task) in inflight where id != song.id {
            task.cancel()
            inflight[id] = nil
        }
        guard inflight[song.id] == nil else { return }
        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.download(song)
        }
        inflight[song.id] = task
        Task { [weak self] in
            _ = await task.value
            self?.inflight[song.id] = nil
            self?.trim()
        }
    }

    func invalidate(songID: String) {
        inflight[songID]?.cancel()
        inflight[songID] = nil
        try? FileManager.default.removeItem(at: destination(for: songID))
    }

    private func destination(for songID: String) -> URL {
        let id = songID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent(id)
    }

    private func download(_ song: Song) async -> URL? {
        guard let remote = client.streamURL(songId: song.id, compatibleWithAirPlay: false) else {
            return nil
        }
        let dest = destination(for: song.id)
        do {
            let (temp, response) = try await client.session.download(from: remote)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let http = response as? HTTPURLResponse,
               let expectedStr = http.value(forHTTPHeaderField: "Content-Length"),
               let expected = Int(expectedStr), expected > 0 {
                if expected > maxFileBytes || size < (expected * 9) / 10 {
                    try? FileManager.default.removeItem(at: temp)
                    return nil
                }
            } else if size > maxFileBytes || size < 48_000 {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            let handle = try FileHandle(forReadingFrom: temp)
            let head = try handle.read(upToCount: 16) ?? Data()
            try handle.close()
            // Subsonic errors come back as XML/JSON with a 200. Don't hand
            // those to AVPlayer as the next track.
            if head.first == 0x3C || head.first == 0x7B || head.first == 0x5B {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func trim() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        let ranked = files.compactMap { url -> (URL, Date, Int)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = values?.contentModificationDate else { return nil }
            return (url, date, values?.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var total = ranked.reduce(0) { $0 + $1.2 }
        for (index, entry) in ranked.enumerated() {
            if index < maxFiles && total <= maxBytes { continue }
            total -= entry.2
            try? fm.removeItem(at: entry.0)
        }
    }
}
