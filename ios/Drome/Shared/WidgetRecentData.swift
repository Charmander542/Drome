import Foundation

/// Recently played + live playback snapshot shared with the home-screen widget.
struct WidgetRecentSnapshot: Codable, Equatable {
    var updatedAt: TimeInterval
    var items: [WidgetRecentItem]
    var nowPlaying: WidgetNowPlaying?

    static let empty = WidgetRecentSnapshot(updatedAt: 0, items: [], nowPlaying: nil)

    /// Seconds without an app sync before treating the session as ended.
    static let staleSyncInterval: TimeInterval = 5 * 60
    /// Seconds paused before medium/large widgets switch to recently played.
    static let pausedIdleInterval: TimeInterval = 3 * 60

    /// True when medium/large should show live transport (playing or recently paused).
    func showsLiveWidget(at date: Date = Date()) -> Bool {
        guard let np = nowPlaying else { return false }
        let now = date.timeIntervalSince1970
        if now - updatedAt > Self.staleSyncInterval { return false }
        if np.isPlaying { return true }
        if let paused = np.pausedSince, now - paused >= Self.pausedIdleInterval { return false }
        return true
    }
}

struct WidgetNowPlaying: Codable, Equatable {
    var songId: String
    var title: String
    var artist: String
    var artworkFile: String?
    var isPlaying: Bool
    var elapsed: TimeInterval
    var duration: TimeInterval
    /// Wall-clock time when `elapsed` was captured (for live progress).
    var capturedAt: TimeInterval
    var rating: Int
    var isOutOfRotation: Bool
    var washR: Double
    var washG: Double
    var washB: Double
    /// When playback last transitioned to paused (for widget idle timeout).
    var pausedSince: TimeInterval?

    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying, duration > 0 else { return min(elapsed, duration) }
        let delta = date.timeIntervalSince1970 - capturedAt
        return min(duration, max(0, elapsed + delta))
    }

    var washColor: (r: Double, g: Double, b: Double) {
        (washR, washG, washB)
    }

    /// Relative luminance 0…1 for picking light vs dark foreground text.
    var luminance: Double {
        0.299 * washR + 0.587 * washG + 0.114 * washB
    }

    var prefersDarkForeground: Bool { luminance > 0.58 }
}

struct WidgetRecentItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var subtitle: String
    /// Filename under App Group `widget-art/`.
    var artworkFile: String?
    /// Resume key for `PlayerEngine.resumeSession(forKey:)`.
    var resumeKey: String
    /// Opens the listening context in Drome (`drome://play?...`).
    var deepLink: String
    var rating: Int
}

enum WidgetRecentStore {
    static let appGroupID = "group.drome.app"
    private static let snapshotName = "widget-recent-plays.json"
    private static let artFolder = "widget-art"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var artDirectoryURL: URL? {
        guard let base = containerURL else { return nil }
        return base.appendingPathComponent(artFolder, isDirectory: true)
    }

    static func load() -> WidgetRecentSnapshot {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(WidgetRecentSnapshot.self, from: data)
        else { return .empty }
        return snap
    }

    static func save(_ snapshot: WidgetRecentSnapshot) {
        guard let url = snapshotURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func artworkURL(for file: String?) -> URL? {
        guard let file, !file.isEmpty, let dir = artDirectoryURL else { return nil }
        return dir.appendingPathComponent(file)
    }

    private static var snapshotURL: URL? {
        containerURL?.appendingPathComponent(snapshotName)
    }
}

enum WidgetDeepLink {
    static func play(resumeKey: String, entryId: String, songId: String?) -> String {
        var items = [
            URLQueryItem(name: "resume", value: resumeKey),
            URLQueryItem(name: "entry", value: entryId),
        ]
        if let songId, !songId.isEmpty {
            items.append(URLQueryItem(name: "song", value: songId))
        }
        var components = URLComponents()
        components.scheme = "drome"
        components.host = "play"
        components.queryItems = items
        return components.url?.absoluteString ?? "drome://track/\(songId ?? "")"
    }
}
