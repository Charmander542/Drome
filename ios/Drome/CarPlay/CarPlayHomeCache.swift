import Foundation

/// Short-lived Home / Library payloads so CarPlay tabs can paint instantly
/// on reconnect and avoid re-fetching playlists on every rebuild.
@MainActor
enum CarPlayHomeCache {
    private static var playlists: [Playlist] = []
    private static var playlistsFetchedAt: Date?
    private static var frequent: [Album] = []
    private static var newest: [Album] = []
    private static var dailyMixes: [DailyMix] = []
    private static var lastError: String?

    private static let playlistTTL: TimeInterval = 120
    private static let railTTL: TimeInterval = 90

    static var cachedPlaylists: [Playlist] { playlists }
    static var cachedFrequent: [Album] { frequent }
    static var cachedNewest: [Album] { newest }
    static var cachedDailyMixes: [DailyMix] { dailyMixes }
    static var cachedError: String? { lastError }

    static var playlistsFresh: Bool {
        guard let at = playlistsFetchedAt else { return false }
        return Date().timeIntervalSince(at) < playlistTTL
    }

    static func storePlaylists(_ value: [Playlist]) {
        playlists = value
        playlistsFetchedAt = Date()
        lastError = nil
    }

    static func storeRails(frequent: [Album], newest: [Album]) {
        self.frequent = frequent
        self.newest = newest
        lastError = nil
    }

    static func storeDailyMixes(_ value: [DailyMix]) {
        dailyMixes = value
    }

    static func storeError(_ message: String) {
        lastError = message
    }

    static func clearError() {
        lastError = nil
    }

    static func invalidate() {
        playlists = []
        playlistsFetchedAt = nil
        frequent = []
        newest = []
        dailyMixes = []
        lastError = nil
    }
}
