import Foundation

/// Pure list / hierarchy policy for CarPlay audio apps.
///
/// Keeps clamping, depth rules, and Home/Library template *structure* testable
/// without a CarPlay session or `xcodebuild`. Live templates pass runtime
/// `CPListTemplate` maxima in; `buildHomeSpec` / `buildLibrarySpec` are the
/// same blueprints the scene delegate follows.
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
    /// Page size inside a letter list (More… pushes one extra level).
    static let letterPageSize = 20
    static let letterPageSizeLimited = 8

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

        var letterPageSize: Int {
            listsLimited ? letterPageSizeLimited : CarPlayListPolicy.letterPageSize
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

    /// Inputs for the shared Home blueprint (also used by XCTest fixtures).
    struct HomeInput: Sendable, Equatable {
        var serverError: Bool
        var recentTitles: [String]
        var frequentTitles: [String]
        var playlistTitles: [String]
        var mixTitles: [String]
        var vibeTitles: [String]

        static let empty = HomeInput(
            serverError: false,
            recentTitles: [], frequentTitles: [], playlistTitles: [],
            mixTitles: [], vibeTitles: [])
    }

    struct LibraryInput: Sendable, Equatable {
        var serverError: Bool
        var playlistTitles: [String]
        var downloadedCount: Int
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

    /// Letter buckets for A–Z browse. Returns **full** sorted lists per letter
    /// (index + letter content page with in-place More… — nothing unreachable).
    static func letterBuckets<T>(
        _ values: [T],
        name: (T) -> String
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
        return order.map { letter in
            let items = (grouped[letter] ?? []).sorted {
                name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
            return (letter, items)
        }
    }

    /// One page of a list (letter index or letter contents). More… must update
    /// the current template in place — never push another level.
    static func letterPage<T>(
        _ items: [T],
        offset: Int,
        pageSize: Int
    ) -> (page: [T], nextOffset: Int?, remaining: Int) {
        let size = max(1, pageSize)
        let page = Array(items.dropFirst(offset).prefix(size))
        let next = offset + page.count
        if next < items.count {
            return (page, next, items.count - next)
        }
        return (page, nil, 0)
    }

    /// Depth for Library → Artists/Albums → letter → (optional in-place More) → item.
    /// In-place More… does **not** add depth.
    static func browseDepth(
        repeatedMorePages: Int,
        opensItem: Bool,
        listsLimited: Bool
    ) -> Int {
        // root tab(1) + browse list(2) + letter page(3) + optional item(4)
        _ = repeatedMorePages
        _ = listsLimited
        return opensItem ? 4 : 3
    }

    // MARK: - Shared template blueprints (scene delegate + XCTest)

    /// Structure the CarPlay Home tab follows. Image-row sections use the row
    /// title only (no duplicate section header).
    static func buildHomeSpec(_ input: HomeInput, tileCap: Int = homeImageRowTiles) -> TemplateSpec {
        if input.serverError {
            return TemplateSpec(
                title: "Home",
                tabTitle: "Home",
                sections: [
                    SectionSpec(items: [
                        ItemSpec(title: "Can't reach your server",
                                 subtitle: "Check Wi‑Fi or your Navidrome URL"),
                        ItemSpec(title: "Retry", subtitle: "Try loading again",
                                 hasImage: true)
                    ])
                ])
        }

        var sections: [SectionSpec] = []
        var quick: [ItemSpec] = [
            ItemSpec(title: "Shuffle All", subtitle: "Random from your library", hasImage: true)
        ]
        let cap = max(1, tileCap)
        if !input.mixTitles.isEmpty {
            quick.append(ItemSpec(
                title: "Daily Mixes", hasImage: true,
                imageRowTitles: Array(input.mixTitles.prefix(cap))))
        }
        if !input.vibeTitles.isEmpty {
            quick.append(ItemSpec(
                title: "Vibe Tuner", hasImage: true,
                imageRowTitles: Array(input.vibeTitles.prefix(cap))))
        }
        sections.append(SectionSpec(header: "Quick Play", items: quick))

        if !input.recentTitles.isEmpty {
            sections.append(SectionSpec(items: [
                ItemSpec(title: "Recently Played", hasImage: true,
                         imageRowTitles: Array(input.recentTitles.prefix(cap)))
            ]))
        }
        if !input.frequentTitles.isEmpty {
            sections.append(SectionSpec(items: [
                ItemSpec(title: "Jump Back In", hasImage: true,
                         imageRowTitles: Array(input.frequentTitles.prefix(cap)))
            ]))
        }
        if !input.playlistTitles.isEmpty {
            sections.append(SectionSpec(items: [
                ItemSpec(title: "Playlists", hasImage: true,
                         imageRowTitles: Array(input.playlistTitles.prefix(cap)))
            ]))
        }

        let onlyQuick = sections.count == 1 && quick.count <= 1
        if onlyQuick {
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
        return TemplateSpec(title: "Home", tabTitle: "Home", sections: sections)
    }

    static func buildLibrarySpec(_ input: LibraryInput, playlistCap: Int) -> TemplateSpec {
        if input.serverError {
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
            ItemSpec(
                title: "Downloaded",
                subtitle: input.downloadedCount == 0
                    ? "Offline music" : "\(input.downloadedCount) songs",
                hasImage: true, accessory: "disclosure"),
            ItemSpec(title: "Artists", subtitle: "Browse your artists",
                     hasImage: true, accessory: "disclosure"),
            ItemSpec(title: "Albums", subtitle: "A–Z by album name",
                     hasImage: true, accessory: "disclosure"),
            ItemSpec(title: "Top Rated", subtitle: "5★, 4★ & up, top albums",
                     hasImage: true, accessory: "disclosure"),
            ItemSpec(title: "Genres", subtitle: "Browse by genre",
                     hasImage: true, accessory: "disclosure")
        ]
        let playlists = Array(input.playlistTitles.prefix(max(0, playlistCap))).map {
            ItemSpec(title: $0, hasImage: true, accessory: "disclosure")
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

    static func buildSearchChooserSpec() -> TemplateSpec {
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

    // MARK: - Fixture trees (XCTest)

    static func fixtureHome(online: Bool, empty: Bool, serverError: Bool) -> TemplateSpec {
        if serverError || !online {
            return buildHomeSpec(HomeInput(
                serverError: true,
                recentTitles: [], frequentTitles: [], playlistTitles: [],
                mixTitles: [], vibeTitles: []))
        }
        if empty {
            return buildHomeSpec(.empty)
        }
        return buildHomeSpec(HomeInput(
            serverError: false,
            recentTitles: ["Song A", "Album B", "Mix C", "Playlist D"],
            frequentTitles: ["Album 1", "Album 2", "Album 3"],
            playlistTitles: ["Gym", "Focus", "Road Trip"],
            mixTitles: ["Daily Mix 1", "Daily Mix 2", "Daily Mix 3"],
            vibeTitles: ["Hype", "Chill", "Feel-Good", "Focus"]))
    }

    static func fixtureLibrary(serverError: Bool, playlistCount: Int) -> TemplateSpec {
        buildLibrarySpec(
            LibraryInput(
                serverError: serverError,
                playlistTitles: (0..<playlistCount).map { "Playlist \($0)" },
                downloadedCount: 12),
            playlistCap: libraryBrowseCap)
    }

    static func fixtureSearchChooser() -> TemplateSpec { buildSearchChooserSpec() }

    static func fixtureNowPlayingMusicButtons() -> [String] {
        ["Rate", "Shuffle", "Repeat", "Autoplay"]
    }

    static func fixtureNowPlayingPodcastButtons() -> [String] {
        ["Back 15", "Forward 30", "Speed"]
    }

    /// Max navigation depth for common paths (root tab counts as 1).
    static func depth(for path: [String]) -> Int { path.count }

    static func assertWithinDepth(_ path: [String]) -> Bool {
        depth(for: path) <= absoluteMaxDepth
    }

    /// Text dump used by XCTest / DEBUG (no CarPlay framework required).
    static func dumpSpec(_ spec: TemplateSpec, limits: Limits) -> String {
        let clamped = clamp(spec.sections, limits: limits)
        var lines: [String] = []
        lines.append("tab=\(spec.tabTitle ?? spec.title) title=\(spec.title)")
        lines.append(
            "sections=\(clamped.count)/\(limits.maxSections) items=\(clamped.reduce(0) { $0 + $1.items.count })/\(limits.maxItems)")
        for (si, section) in clamped.enumerated() {
            lines.append("  section[\(si)] header=\(section.header ?? "nil") items=\(section.items.count)")
            for (ii, item) in section.items.enumerated() {
                var row = "    [\(ii)] \"\(item.title)\""
                if let sub = item.subtitle { row += " — \"\(sub)\"" }
                row += " img=\(item.hasImage ? "y" : "n")"
                if let acc = item.accessory { row += " accessory=\(acc)" }
                if let tiles = item.imageRowTitles {
                    row += " tiles=[\(tiles.joined(separator: ", "))]"
                }
                lines.append(row)
            }
        }
        if let np = spec.nowPlayingButtons {
            lines.append("  nowPlayingButtons: \(np.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
