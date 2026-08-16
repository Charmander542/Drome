#if os(tvOS)
import Foundation

/// Apple TV's FigFilePlayer cannot decode FLAC/ALAC/WAV (err -12864), even
/// from a local file. Cache a complete MP3 and play that path instead of HTTP.
@MainActor
final class TVPlaybackCache {
    private let client: SubsonicClient
    private let directory: URL
    private var inflight: [String: Task<URL, Error>] = [:]

    init(client: SubsonicClient) {
        self.client = client
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // Drop the earlier lossless cache — those files are silent on Apple TV.
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("DromeTVPlay"))
        directory = caches.appendingPathComponent("DromeTVAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cachedURL(for song: Song) -> URL? {
        let url = destination(for: song)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 2048 else { return nil }
        return url
    }

    func fileURL(for song: Song) async throws -> URL {
        if let cached = cachedURL(for: song) {
            touch(cached)
            return cached
        }
        if let existing = inflight[song.id] {
            return try await existing.value
        }
        let task = Task<URL, Error> { [client, directory] in
            try await Self.download(song: song, client: client, directory: directory)
        }
        inflight[song.id] = task
        defer { inflight[song.id] = nil }
        let url = try await task.value
        trim()
        return url
    }

    func prefetch(_ song: Song) {
        guard cachedURL(for: song) == nil, inflight[song.id] == nil else { return }
        Task { _ = try? await fileURL(for: song) }
    }

    private func destination(for song: Song) -> URL {
        Self.destination(for: song, in: directory)
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path)
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
        let maxFiles = 12
        let maxBytes = 800_000_000
        for (index, entry) in ranked.enumerated() {
            if index < maxFiles && total <= maxBytes { continue }
            total -= entry.2
            try? fm.removeItem(at: entry.0)
        }
    }

    private static func destination(for song: Song, in directory: URL) -> URL {
        let id = song.id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("\(id).mp3")
    }

    private static func isAlreadyMP3(_ song: Song) -> Bool {
        let suffix = (song.suffix ?? "").lowercased()
        let type = (song.contentType ?? "").lowercased()
        if suffix == "mp3" { return true }
        return type == "audio/mpeg" || type == "audio/mp3"
    }

    private static func looksLikeUnsupportedOriginal(_ head: Data) -> Bool {
        if head.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return true } // fLaC
        if head.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return true } // OggS
        if head.count >= 8,
           head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70 {
            return true // ftyp (m4a/alac)
        }
        if head.starts(with: [0x52, 0x49, 0x46, 0x46]) { return true } // WAV
        return false
    }

    private static func download(song: Song, client: SubsonicClient, directory: URL) async throws -> URL {
        let remote: URL?
        if isAlreadyMP3(song) {
            remote = client.downloadURL(songId: song.id) ?? client.streamURL(songId: song.id, format: "raw", maxBitRate: nil)
        } else {
            remote = client.streamURL(songId: song.id, format: "mp3", maxBitRate: 320)
        }
        guard let remote else { throw URLError(.badURL) }

        let dest = destination(for: song, in: directory)
        let (temp, response) = try await client.session.download(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let handle = try FileHandle(forReadingFrom: temp)
        let head = try handle.read(upToCount: 32) ?? Data()
        try handle.close()
        if head.isEmpty || head.first == 0x3C || looksLikeUnsupportedOriginal(head) {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.cannotDecodeContentData)
        }
        // Prefer MPEG, but keep the file if the server sent a transcode we can try.
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }
}
#endif
