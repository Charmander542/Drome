import Foundation

/// Wire format for iPhone ↔ Apple Watch playback control (no server).
enum WatchBridgeKey {
    static let snapshotJSON = "snapshotJSON"
    static let command = "command"
    static let rating = "rating"
    static let resumeKey = "resumeKey"
    static let entryId = "entryId"
    static let songId = "songId"
    static let playlistId = "playlistId"
    static let volumeDelta = "volumeDelta"
    static let artworkSongId = "artworkSongId"
    static let artworkJPEG = "artworkJPEG"
}

enum WatchCommand: String, Codable {
    case togglePlay
    case next
    case previous
    case toggleLike
    case toggleOutOfRotation
    case setRating
    case playContext
    case playPlaylist
    case adjustVolume
    case requestSync
}

struct WatchPlaylistItem: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var songCount: Int
}

struct WatchNowPlaying: Codable, Equatable {
    var songId: String
    var title: String
    var artist: String
    var isPlaying: Bool
    var elapsed: TimeInterval
    var duration: TimeInterval
    var capturedAt: TimeInterval
    var rating: Int
    var isOutOfRotation: Bool
    var washR: Double
    var washG: Double
    var washB: Double

    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying, duration > 0 else { return min(elapsed, duration) }
        let delta = date.timeIntervalSince1970 - capturedAt
        return min(duration, max(0, elapsed + delta))
    }

    var washColor: (r: Double, g: Double, b: Double) {
        (washR, washG, washB)
    }
}

struct WatchRecentItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var resumeKey: String
    var rating: Int
}

/// Playback state pushed from iPhone → Watch.
struct WatchPlaybackPayload: Codable, Equatable {
    var updatedAt: TimeInterval
    var nowPlaying: WatchNowPlaying?
    var recents: [WatchRecentItem]
    var playlists: [WatchPlaylistItem]
    var artworkSongId: String?
}

extension WatchPlaybackPayload {
    static var empty: WatchPlaybackPayload {
        WatchPlaybackPayload(
            updatedAt: 0,
            nowPlaying: nil,
            recents: [],
            playlists: [],
            artworkSongId: nil)
    }
}

#if os(iOS)
extension WatchNowPlaying {
    init(_ widget: WidgetNowPlaying) {
        songId = widget.songId
        title = widget.title
        artist = widget.artist
        isPlaying = widget.isPlaying
        elapsed = widget.elapsed
        duration = widget.duration
        capturedAt = widget.capturedAt
        rating = widget.rating
        isOutOfRotation = widget.isOutOfRotation
        washR = widget.washR
        washG = widget.washG
        washB = widget.washB
    }
}

extension WatchRecentItem {
    init(_ widget: WidgetRecentItem) {
        id = widget.id
        title = widget.title
        subtitle = widget.subtitle
        resumeKey = widget.resumeKey
        rating = widget.rating
    }
}

extension WatchPlaybackPayload {
    static func fromWidgetSnapshot(
        _ snapshot: WidgetRecentSnapshot,
        playlists: [WatchPlaylistItem]
    ) -> WatchPlaybackPayload {
        WatchPlaybackPayload(
            updatedAt: snapshot.updatedAt,
            nowPlaying: snapshot.nowPlaying.map(WatchNowPlaying.init),
            recents: snapshot.items.map(WatchRecentItem.init),
            playlists: playlists,
            artworkSongId: snapshot.nowPlaying?.songId)
    }
}
#endif

enum WatchArtStore {
    static func artworkURL(for songId: String) -> URL? {
        guard let dir = artDirectory else { return nil }
        return dir.appendingPathComponent("\(sanitized(songId)).jpg")
    }

    static var artDirectory: URL? {
        #if os(watchOS)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("watch-art", isDirectory: true)
        #else
        nil
        #endif
    }

    static func saveArtwork(_ data: Data, songId: String) {
        #if os(watchOS)
        guard let dir = artDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sanitized(songId)).jpg")
        try? data.write(to: url, options: .atomic)
        #endif
    }

    private static func sanitized(_ raw: String) -> String {
        raw.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}
