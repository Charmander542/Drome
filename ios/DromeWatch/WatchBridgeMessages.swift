import Foundation
import WatchConnectivity

/// Watch-side playback mirror types (kept in sync with `WatchBridgeMessages.swift` on iPhone).
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
    case togglePlay, next, previous, toggleLike, toggleOutOfRotation
    case setRating, playContext, playPlaylist, adjustVolume, requestSync
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

    var washColor: (r: Double, g: Double, b: Double) { (washR, washG, washB) }
}

struct WatchRecentItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var resumeKey: String
    var rating: Int
}

struct WatchPlaybackPayload: Codable, Equatable {
    var updatedAt: TimeInterval
    var nowPlaying: WatchNowPlaying?
    var recents: [WatchRecentItem]
    var playlists: [WatchPlaylistItem]
    var artworkSongId: String?

    static var empty: WatchPlaybackPayload {
        WatchPlaybackPayload(updatedAt: 0, nowPlaying: nil, recents: [], playlists: [], artworkSongId: nil)
    }
}

enum WatchArtStore {
    static func artworkURL(for songId: String) -> URL? {
        guard let dir = artDirectory else { return nil }
        return dir.appendingPathComponent("\(sanitized(songId)).jpg")
    }

    static var artDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("watch-art", isDirectory: true)
    }

    static func saveArtwork(_ data: Data, songId: String) {
        guard let dir = artDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(sanitized(songId)).jpg"), options: .atomic)
    }

    private static func sanitized(_ raw: String) -> String {
        raw.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
    }
}
