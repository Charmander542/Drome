import Foundation
import WidgetKit

/// On-watch snapshot store shared with the WidgetKit extension via App Group.
enum WatchWidgetStore {
    static let appGroupID = "group.drome.app"
    private static let snapshotName = "watch-widget-snapshot.json"
    private static let artFolder = "watch-widget-art"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var artDirectoryURL: URL? {
        containerURL?.appendingPathComponent(artFolder, isDirectory: true)
    }

    static func load() -> WatchPlaybackPayload {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(WatchPlaybackPayload.self, from: data)
        else { return .empty }
        return payload
    }

    static func save(_ payload: WatchPlaybackPayload) {
        guard let url = snapshotURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func saveArtwork(_ data: Data, songId: String) {
        guard let dir = artDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sanitized(songId)).jpg")
        try? data.write(to: file, options: .atomic)
    }

    static func artworkURL(for songId: String?) -> URL? {
        guard let songId, let dir = artDirectoryURL else { return nil }
        return dir.appendingPathComponent("\(sanitized(songId)).jpg")
    }

    static func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func sync(_ payload: WatchPlaybackPayload) {
        save(payload)
        if let songId = payload.artworkSongId,
           let cacheURL = WatchArtStore.artworkURL(for: songId),
           let data = try? Data(contentsOf: cacheURL) {
            saveArtwork(data, songId: songId)
        }
        reloadTimelines()
    }

    private static var snapshotURL: URL? {
        containerURL?.appendingPathComponent(snapshotName)
    }

    private static func sanitized(_ raw: String) -> String {
        raw.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
    }
}

extension WatchPlaybackPayload {
    static let staleSyncInterval: TimeInterval = 5 * 60

    func showsNowPlaying(at date: Date = Date()) -> Bool {
        guard nowPlaying != nil else { return false }
        return date.timeIntervalSince1970 - updatedAt <= Self.staleSyncInterval
    }
}
