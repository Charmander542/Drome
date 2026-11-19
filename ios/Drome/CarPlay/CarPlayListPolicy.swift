import Foundation

/// Pure list / hierarchy policy for CarPlay audio apps.
///
/// Keeps clamping and depth rules testable without a CarPlay session or
/// `xcodebuild`. Live templates pass runtime `CPListTemplate` maxima in.
enum CarPlayListPolicy: Sendable {
    /// CarPlay audio entitlement cap (root included).
    static let absoluteMaxDepth = 5
    /// Preferred max pushes including root — leave headroom for Now Playing.
    static let preferredMaxDepth = 4
    /// When `CPLimitableUserInterface.lists` is active, many vehicles show 12.
    static let limitedListItemCap = 12
    /// Comfortable home image-row tile count (system may show fewer).
    static let homeImageRowTiles = 8
    /// Library playlist / browse caps when not in limited UI.
    static let libraryBrowseCap = 40
    static let detailTrackCap = 80

    struct Limits: Sendable, Equatable {
        var maxSections: Int
        var maxItems: Int
        /// True when the vehicle enforces shorter lists.
        var listsLimited: Bool

        static func resolve(
            maximumSectionCount: Int,
            maximumItemCount: Int,
            listsLimited: Bool
        ) -> Limits {
            let sections = max(1, maximumSectionCount)
            var items = max(1, maximumItemCount)
            if listsLimited {
                items = min(items, limitedListItemCap)
            }
            return Limits(maxSections: sections, maxItems: items, listsLimited: listsLimited)
        }
    }

    struct SectionSpec: Sendable, Equatable {
        var header: String?
        var items: [ItemSpec]

        init(header: String? = nil, items: [ItemSpec]) {
            self.header = header
            self.items = items
        }
    }

    struct ItemSpec: Sendable, Equatable {
        var title: String
        var subtitle: String?
        var hasImage: Bool
        var accessory: String?
        /// Image-row tile titles (when this item represents a `CPListImageRowItem`).
        var imageRowTitles: [String]?

        init(
            title: String,
            subtitle: String? = nil,
            hasImage: Bool = false,
            accessory: String? = nil,
            imageRowTitles: [String]? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.hasImage = hasImage
            self.accessory = accessory
            self.imageRowTitles = imageRowTitles
        }

        var isImageRow: Bool { imageRowTitles != nil }
    }

    struct TemplateSpec: Sendable, Equatable {
        var title: String
        var tabTitle: String?
        var sections: [SectionSpec]
        var nowPlayingButtons: [String]?

        var totalItems: Int { sections.reduce(0) { $0 + $1.items.count } }
    }

    /// Clamp section/item counts to CarPlay maxima. Preserves leading sections
    /// (quick actions / errors) and trims trailing items first within a section.
    static func clamp(_ sections: [SectionSpec], limits: Limits) -> [SectionSpec] {
        guard !sections.isEmpty else { return sections }

        var remainingItems = limits.maxItems
        var result: [SectionSpec] = []

        for section in sections.prefix(limits.maxSections) {
            guard remainingItems > 0 else { break }
            let take = min(section.items.count, remainingItems)
            guard take > 0 else { continue }
            result.append(SectionSpec(
                header: section.header,
                items: Array(section.items.prefix(take))))
            remainingItems -= take
        }
        return result
    }

    /// Letter buckets for A–Z browse (replaces “Load More” push chains).
    static func letterBuckets<T>(
        _ values: [T],
        name: (T) -> String,
        maxPerLetter: Int,
        maxLetters: Int
    ) -> [(letter: String, items: [T])] {
        let grouped = Dictionary(grouping: values) { value -> String in
            let trimmed = name(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else { return "#" }
            let upper = String(first).uppercased()
            if upper.first?.isLetter == true { return upper }
            return "#"
        }
        let order = grouped.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return order.prefix(maxLetters).map { letter in
            let items = (grouped[letter] ?? []).sorted {
                name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
            return (letter, Array(items.prefix(maxPerLetter)))
        }
    }

    // MARK: - Fixture trees (for XCTest / DEBUG dumps)

    static func fixtureHome(online: Bool, empty: Bool, serverError: Bool) -> TemplateSpec {
        if serverError {
            return TemplateSpec(
                title: "Home",
                tabTitle: "Home",
                sections: [
                    SectionSpec(items: [
                        ItemSpec(title: "Can't reach your server",
                                 subtitle: "Check Wi‑Fi or your Navidrome URL"),
                        ItemSpec(title: "Retry", subtitle: "Try loading Home again",
                                 hasImage: true)
                    ])
                ])
        }
        if empty {
            return TemplateSpec(
                title: "Home",
                tabTitle: "Home",
                sections: [
                    SectionSpec(items: [
                        ItemSpec(title: "Nothing here yet",
                                 subtitle: "Play music on your iPhone to fill Home")
                    ])
                ])
        }
        if !online {
            return TemplateSpec(
                title: "Home",
                tabTitle: "Home",
                sections: [
                    SectionSpec(items: [
                        ItemSpec(title: "Can't reach your server",
                                 subtitle: "Check Wi‑Fi or your Navidrome URL"),
                        ItemSpec(title: "Retry", hasImage: true)
                    ])
                ])
        }

        return TemplateSpec(
            title: "Home",
            tabTitle: "Home",
            sections: [
                SectionSpec(header: "Quick Play", items: [
                    ItemSpec(title: "Shuffle All", subtitle: "Random from your library",
                             hasImage: true),
                    ItemSpec(title: "Daily Mixes", hasImage: true,
                             imageRowTitles: ["Daily Mix 1", "Daily Mix 2", "Daily Mix 3"]),
                    ItemSpec(title: "Vibe Tuner", hasImage: true,
                             imageRowTitles: ["Hype", "Chill", "Feel-Good", "Focus"])
                ]),
                SectionSpec(header: "Recently Played", items: [
                    ItemSpec(title: "Recently Played", hasImage: true,
                             imageRowTitles: ["Song A", "Album B", "Mix C", "Playlist D"])
                ]),
                SectionSpec(header: "Jump Back In", items: [
                    ItemSpec(title: "Jump Back In", hasImage: true,
                             imageRowTitles: ["Album 1", "Album 2", "Album 3"])
                ]),
                SectionSpec(header: "Playlists", items: [
                    ItemSpec(title: "Playlists", hasImage: true,
                             imageRowTitles: ["Gym", "Focus", "Road Trip"])
                ])
            ])
    }

    static func fixtureLibrary(serverError: Bool, playlistCount: Int) -> TemplateSpec {
        if serverError {
            return TemplateSpec(
                title: "Your Library",
                tabTitle: "Your Library",
                sections: [
                    SectionSpec(items: [
                        ItemSpec(title: "Can't reach your server",
                                 subtitle: "Check Wi‑Fi or your Navidrome URL"),
                        ItemSpec(title: "Retry", hasImage: true)
                    ])
                ])
        }
        let browse = [
            ItemSpec(title: "Downloaded", hasImage: true, accessory: "disclosure"),
            ItemSpec(title: "Artists", hasImage: true, accessory: "disclosure"),
            ItemSpec(title: "Albums", hasImage: true, accessory: "disclosure"),
            ItemSpec(title: "Top Rated", hasImage: true, accessory: "disclosure"),
            ItemSpec(title: "Genres", hasImage: true, accessory: "disclosure")
        ]
        let playlists = (0..<playlistCount).map {
            ItemSpec(title: "Playlist \($0)", hasImage: true, accessory: "disclosure")
        }
        return TemplateSpec(
            title: "Your Library",
            tabTitle: "Your Library",
            sections: [
                SectionSpec(header: "Browse", items: browse),
                SectionSpec(header: "Playlists", items: playlists.isEmpty
                            ? [ItemSpec(title: "No playlists",
                                        subtitle: "Create one on your iPhone")]
                            : playlists)
            ])
    }

    static func fixtureSearchChooser() -> TemplateSpec {
        TemplateSpec(
            title: "Search",
            tabTitle: "Search",
            sections: [
                SectionSpec(items: [
                    ItemSpec(title: "Voice search", subtitle: "Dictation in the search field",
                             hasImage: true),
                    ItemSpec(title: "Keyboard", subtitle: "On-screen letter pad",
                             hasImage: true)
                ])
            ])
    }

    static func fixtureNowPlayingMusicButtons() -> [String] {
        ["Rate", "Shuffle", "Repeat", "Autoplay"]
    }

    static func fixtureNowPlayingPodcastButtons() -> [String] {
        ["Back 15", "Forward 30", "Speed"]
    }

    /// Max navigation depth for common paths (root tab counts as 1).
    static func depth(for path: [String]) -> Int { path.count }

    static func assertWithinDepth(_ path: [String], file: StaticString = #file, line: UInt = #line) -> Bool {
        depth(for: path) <= absoluteMaxDepth
    }
}
