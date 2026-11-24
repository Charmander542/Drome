import Foundation

/// Quiet opportunistic refresh of subscribed podcast RSS feeds.
/// Mirrors `LibraryMirrorSync`: single-flight, non-blocking, no UI spinner.
@MainActor
enum PodcastFeedSync {
    /// Skip work when every show was refreshed within this window.
    static let staleInterval: TimeInterval = 30 * 60

    private static var inflight: Task<Void, Never>?

    static func refreshIfNeeded(manager: PodcastManager) {
        guard inflight == nil else { return }
        guard !manager.subscribedShows.isEmpty else { return }

        let cutoff = Date().addingTimeInterval(-staleInterval)
        let needsRefresh = manager.subscribedShows.contains { show in
            guard let updated = show.lastUpdated else { return true }
            return updated < cutoff
        }
        guard needsRefresh else { return }

        inflight = Task {
            defer { inflight = nil }
            DromeDiagnostics.logPodcast("feed sync starting")
            await manager.refreshStaleFeeds(olderThan: staleInterval)
            DromeDiagnostics.logPodcast("feed sync done")
        }
    }
}
