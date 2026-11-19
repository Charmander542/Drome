import Foundation
import Observation

/// Shared tab + search intent so Library / Podcasts can hand off to SearchView
/// whether or not Search has been mounted yet.
@MainActor
@Observable
final class AppNavigationRouter {
    enum Tab: Int, CaseIterable {
        case home = 0
        case search = 1
        case library = 2
        case podcasts = 3
    }

    /// Matches SearchView’s source segmented control.
    enum SearchMode: String, Equatable {
        case library
        case spotify
        case podcasts
    }

    /// Result-type filter applied in Library search mode.
    enum SearchResultFilter: String, CaseIterable, Identifiable, Equatable {
        case all
        case songs
        case albums
        case artists

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .songs: return "Songs"
            case .albums: return "Albums"
            case .artists: return "Artists"
            }
        }

        var accessibilityIdentifier: String {
            "search-filter-\(rawValue)"
        }
    }

    struct SearchIntent: Equatable {
        var mode: SearchMode
        var filter: SearchResultFilter
        /// When true, Search focuses the field once, then clears this flag so
        /// later tab returns do not pop the keyboard again.
        var shouldFocus: Bool
    }

    var selectedTab: Tab = .home
    /// Pending handoff for SearchView. Cleared (or focus-cleared) after consume.
    var pendingSearchIntent: SearchIntent?

    func selectTab(_ tab: Tab) {
        selectedTab = tab
    }

    /// Switch to Search with mode / filter / one-shot focus.
    func openSearch(
        mode: SearchMode,
        filter: SearchResultFilter = .all,
        focus: Bool = true
    ) {
        pendingSearchIntent = SearchIntent(mode: mode, filter: filter, shouldFocus: focus)
        selectedTab = .search
    }

    func openPodcastsSearch(focus: Bool = true) {
        openSearch(mode: .podcasts, filter: .all, focus: focus)
    }

    func openLibrarySearch(
        filter: SearchResultFilter,
        focus: Bool = true
    ) {
        openSearch(mode: .library, filter: filter, focus: focus)
    }
}
