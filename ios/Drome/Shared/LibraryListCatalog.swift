import Foundation

/// Persistent library list catalogs so Playlists / Albums / Artists / Songs
/// paint instantly on tab flips. Memory first, then Application Support disk.
enum LibraryListCatalog {
    private struct Entry<T: Codable>: Codable {
        var items: [T]
        var isComplete: Bool
    }

    struct ArtistSection: Codable, Hashable {
        var letter: String
        var artists: [Artist]
    }

    private struct DiskFile<T: Codable>: Codable {
        var items: [T]
        var isComplete: Bool
        var savedAt: Date
    }

    private static let lock = NSLock()
    private static var albumsByServer: [String: Entry<Album>] = [:]
    private static var artistsByServer: [String: Entry<ArtistSection>] = [:]
    private static var songsByServer: [String: Entry<Song>] = [:]
    private static var playlistsByServer: [String: Entry<Playlist>] = [:]
    private static var loadedDiskKeys: Set<String> = []
    private static var writeGeneration: [String: Int] = [:]

    // MARK: - Playlists

    static func playlists(serverKey: String) -> [Playlist]? {
        ensureDiskLoaded(serverKey: serverKey)
        lock.lock(); defer { lock.unlock() }
        return playlistsByServer[serverKey]?.items
    }

    static func storePlaylists(_ playlists: [Playlist], serverKey: String) {
        lock.lock()
        playlistsByServer[serverKey] = Entry(items: playlists, isComplete: true)
        lock.unlock()
        scheduleDiskWrite(kind: "playlists", serverKey: serverKey, items: playlists, isComplete: true)
    }

    // MARK: - Albums

    static func albums(serverKey: String) -> [Album]? {
        ensureDiskLoaded(serverKey: serverKey)
        lock.lock(); defer { lock.unlock() }
        return albumsByServer[serverKey]?.items
    }

    static func albumsComplete(serverKey: String) -> Bool {
        ensureDiskLoaded(serverKey: serverKey)
        lock.lock(); defer { lock.unlock() }
        return albumsByServer[serverKey]?.isComplete == true
    }

    static func storeAlbums(_ albums: [Album], serverKey: String, isComplete: Bool) {
        lock.lock()
        albumsByServer[serverKey] = Entry(items: albums, isComplete: isComplete)
        lock.unlock()
        scheduleDiskWrite(kind: "albums", serverKey: serverKey, items: albums, isComplete: isComplete)
    }

    // MARK: - Artists

    static func artistSections(serverKey: String) -> [ArtistSection]? {
        ensureDiskLoaded(serverKey: serverKey)
        lock.lock(); defer { lock.unlock() }
        return artistsByServer[serverKey]?.items
    }

    static func artistsComplete(serverKey: String) -> Bool {
        ensureDiskLoaded(serverKey: serverKey)
        lock.lock(); defer { lock.unlock() }
        return artistsByServer[serverKey]?.isComplete == true
    }

    static func storeArtistSections(
        _ sections: [(letter: String, artists: [Artist])],
        serverKey: String,
        isComplete: Bool
    ) {
        let mapped = sections.map { ArtistSection(letter: $0.letter, artists: $0.artists) }
        lock.lock()
        artistsByServer[serverKey] = Entry(items: mapped, isComplete: isComplete)
        lock.unlock()
        scheduleDiskWrite(kind: "artists", serverKey: serverKey, items: mapped, isComplete: isComplete)
    }

    // MARK: - Songs

    static func songs(serverKey: String) -> [Song]? {
        ensureDiskLoaded(serverKey: serverKey)
        lock.lock(); defer { lock.unlock() }
        return songsByServer[serverKey]?.items
    }

    static func songsComplete(serverKey: String) -> Bool {
        ensureDiskLoaded(serverKey: serverKey)
        lock.lock(); defer { lock.unlock() }
        return songsByServer[serverKey]?.isComplete == true
    }

    static func storeSongs(_ songs: [Song], serverKey: String, isComplete: Bool) {
        lock.lock()
        songsByServer[serverKey] = Entry(items: songs, isComplete: isComplete)
        lock.unlock()
        scheduleDiskWrite(kind: "songs", serverKey: serverKey, items: songs, isComplete: isComplete)
    }

    /// Drop memory + disk after a library scan so the next load refreshes.
    static func invalidate(serverKey: String) {
        lock.lock()
        albumsByServer.removeValue(forKey: serverKey)
        artistsByServer.removeValue(forKey: serverKey)
        songsByServer.removeValue(forKey: serverKey)
        playlistsByServer.removeValue(forKey: serverKey)
        loadedDiskKeys.remove(serverKey)
        lock.unlock()
        let dir = directory(for: serverKey)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Disk

    private static func ensureDiskLoaded(serverKey: String) {
        lock.lock()
        let already = loadedDiskKeys.contains(serverKey)
        lock.unlock()
        guard !already else { return }

        let albums = readDisk(kind: "albums", serverKey: serverKey, as: Album.self)
        let artists = readDisk(kind: "artists", serverKey: serverKey, as: ArtistSection.self)
        let songs = readDisk(kind: "songs", serverKey: serverKey, as: Song.self)
        let playlists = readDisk(kind: "playlists", serverKey: serverKey, as: Playlist.self)

        lock.lock()
        if loadedDiskKeys.contains(serverKey) {
            lock.unlock()
            return
        }
        if let albums {
            albumsByServer[serverKey] = Entry(items: albums.items, isComplete: albums.isComplete)
        }
        if let artists {
            artistsByServer[serverKey] = Entry(items: artists.items, isComplete: artists.isComplete)
        }
        if let songs {
            songsByServer[serverKey] = Entry(items: songs.items, isComplete: songs.isComplete)
        }
        if let playlists {
            playlistsByServer[serverKey] = Entry(items: playlists.items, isComplete: true)
        }
        loadedDiskKeys.insert(serverKey)
        lock.unlock()
    }

    private static func scheduleDiskWrite<T: Codable>(
        kind: String,
        serverKey: String,
        items: [T],
        isComplete: Bool
    ) {
        lock.lock()
        let next = (writeGeneration["\(serverKey)|\(kind)"] ?? 0) + 1
        writeGeneration["\(serverKey)|\(kind)"] = next
        lock.unlock()

        let snapshot = DiskFile(items: items, isComplete: isComplete, savedAt: Date())
        Task.detached(priority: .utility) {
            Self.writeDisk(kind: kind, serverKey: serverKey, generation: next, file: snapshot)
        }
    }

    private static func writeDisk<T: Codable>(
        kind: String,
        serverKey: String,
        generation: Int,
        file: DiskFile<T>
    ) {
        lock.lock()
        let current = writeGeneration["\(serverKey)|\(kind)"] ?? 0
        lock.unlock()
        guard generation == current else { return }

        let dir = directory(for: serverKey)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(kind).json")
            let data = try JSONEncoder().encode(file)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Cache write is best-effort.
        }
    }

    private static func readDisk<T: Codable>(
        kind: String,
        serverKey: String,
        as type: T.Type
    ) -> DiskFile<T>? {
        let url = directory(for: serverKey).appendingPathComponent("\(kind).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DiskFile<T>.self, from: data)
    }

    private static func directory(for serverKey: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DromeLibraryCatalog", isDirectory: true)
        let safe = serverKey
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_")))
            ?? "server"
        return root.appendingPathComponent(safe, isDirectory: true)
    }
}
