import Foundation

// MARK: - Podcast Show

/// A podcast show (feed) with metadata from the RSS feed.
struct PodcastShow: Codable, Identifiable, Hashable, Equatable {
    let id: String              // Feed URL (stable identifier)
    var title: String
    var author: String?
    var description: String?
    var imageURL: URL?
    var language: String?
    var category: String?
    var explicit: Bool
    var link: URL?
    var episodeCount: Int
    var lastUpdated: Date?
    var feedURL: String         // Canonical feed URL

    var idHash: String {
        // Stable short ID derived from feed URL for database keys
        let data = feedURL.data(using: .utf8) ?? Data()
        return String(data.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    init(id: String = UUID().uuidString, title: String, author: String? = nil,
         description: String? = nil, imageURL: URL? = nil, language: String? = nil,
         category: String? = nil, explicit: Bool = false, link: URL? = nil,
         episodeCount: Int = 0, lastUpdated: Date? = nil, feedURL: String) {
        self.id = id
        self.title = title
        self.author = author
        self.description = description
        self.imageURL = imageURL
        self.language = language
        self.category = category
        self.explicit = explicit
        self.link = link
        self.episodeCount = episodeCount
        self.lastUpdated = lastUpdated
        self.feedURL = feedURL
    }
}

// MARK: - Podcast Episode

/// A single podcast episode.
struct PodcastEpisode: Codable, Identifiable, Hashable, Equatable {
    let id: String              // Enclosure URL or GUID
    let showID: String          // Parent show's feed URL
    var title: String
    var description: String?
    var pubDate: Date?
    var duration: TimeInterval? // In seconds
    var audioURL: URL           // Enclosure/stream URL
    var imageURL: URL?          // Episode-specific image (falls back to show image)
    var episodeNumber: Int?
    var seasonNumber: Int?
    var episodeType: String?    // full, trailer, bonus
    var explicit: Bool
    var fileSize: Int64?
    var mimeType: String?

    /// Playback position in seconds (persisted per episode).
    var playbackPosition: TimeInterval = 0

    var durationText: String {
        guard let duration else { return "Unknown" }
        let seconds = max(0, Int(duration))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var isFullyPlayed: Bool {
        guard let duration, duration > 0 else { return false }
        return playbackPosition >= duration * 0.95
    }

    var progressFraction: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(1.0, playbackPosition / duration)
    }

    /// Seconds still left to listen (nil when duration is unknown).
    var remainingSeconds: TimeInterval? {
        guard let duration, duration > 0 else { return nil }
        return max(0, duration - playbackPosition)
    }

    /// Podcast-style remaining label, e.g. "23 min left".
    var remainingText: String? {
        guard let remaining = remainingSeconds else { return nil }
        let seconds = Int(remaining.rounded())
        if seconds < 60 { return "\(max(1, seconds)) sec left" }
        let minutes = (seconds + 30) / 60
        if minutes < 60 {
            return "\(minutes) min left"
        }
        let hours = minutes / 60
        let remMins = minutes % 60
        if remMins == 0 { return "\(hours) hr left" }
        return "\(hours) hr \(remMins) min left"
    }
}

// MARK: - Podcast Queue Item

/// A podcast episode wrapped for the playback queue.
struct PodcastQueueItem: Identifiable, Equatable {
    let id: UUID
    let episode: PodcastEpisode

    init(episode: PodcastEpisode) {
        self.id = UUID()
        self.episode = episode
    }
}

// MARK: - Podcast Discover Result

/// A podcast found during discovery/search (from directory or RSS lookup).
struct PodcastDiscoverResult: Identifiable {
    let id: String
    let show: PodcastShow
    let source: String // "directory" | "rss" | "search"
}
