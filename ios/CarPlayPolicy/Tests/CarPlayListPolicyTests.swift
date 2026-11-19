import XCTest
@testable import CarPlayListPolicy

/// Headless verification of CarPlay template blueprints used by
/// `CarPlaySceneDelegate` (online / empty / offline).
/// Run via `ios/scripts/test-carplay-policy.sh`.
final class CarPlayListPolicyTests: XCTestCase {
    private let defaultLimits = CarPlayListPolicy.Limits(
        maxSections: 8, maxItems: 20, listsLimited: false)
    private let limitedLimits = CarPlayListPolicy.Limits(
        maxSections: 4, maxItems: 12, listsLimited: true)

    func testClampRespectsItemAndSectionCaps() {
        let limits = CarPlayListPolicy.Limits(
            maxSections: 3, maxItems: 5, listsLimited: false)
        let sections = (0..<6).map { s in
            CarPlayListPolicy.SectionSpec(
                header: "S\(s)",
                items: (0..<4).map {
                    CarPlayListPolicy.ItemSpec(title: "S\(s)-\($0)")
                })
        }
        let clamped = CarPlayListPolicy.clamp(sections, limits: limits)
        XCTAssertLessThanOrEqual(clamped.count, 3)
        XCTAssertEqual(clamped.reduce(0) { $0 + $1.items.count }, 5)
    }

    func testLimitedUIUsesTwelveItemCap() {
        let limits = CarPlayListPolicy.Limits.resolve(
            maximumSectionCount: 10,
            maximumItemCount: 100,
            listsLimited: true)
        XCTAssertEqual(limits.maxItems, CarPlayListPolicy.limitedListItemCap)
        XCTAssertEqual(limits.letterPageSize, CarPlayListPolicy.letterPageSizeLimited)
    }

    func testBuildHomeSpecOnlineThroughRealBlueprint() {
        let input = CarPlayListPolicy.HomeInput(
            serverError: false,
            recentTitles: ["Song A", "Album B", "Mix C"],
            frequentTitles: ["Album 1", "Album 2"],
            playlistTitles: ["Gym", "Focus"],
            mixTitles: ["Daily Mix 1", "Daily Mix 2"],
            vibeTitles: ["Hype", "Chill", "Focus"])
        let home = CarPlayListPolicy.buildHomeSpec(input)
        let clamped = CarPlayListPolicy.clamp(home.sections, limits: limitedLimits)
        XCTAssertLessThanOrEqual(clamped.count, limitedLimits.maxSections)
        XCTAssertLessThanOrEqual(
            clamped.reduce(0) { $0 + $1.items.count }, limitedLimits.maxItems)
        XCTAssertEqual(clamped.first?.header, "Quick Play")
        XCTAssertTrue(clamped.flatMap(\.items).contains { $0.title == "Shuffle All" })
        XCTAssertTrue(clamped.flatMap(\.items).contains { $0.isImageRow })
        for section in clamped where section.items.contains(where: \.isImageRow)
            && section.header != "Quick Play" {
            XCTAssertNil(section.header)
        }

        let dump = CarPlayListPolicy.dumpSpec(home, limits: limitedLimits)
        print("--- CarPlay Home dump (online) ---\n\(dump)")
        XCTAssertTrue(dump.contains("Shuffle All"))
        XCTAssertTrue(dump.contains("Daily Mixes") || dump.contains("Vibe Tuner"))
    }

    func testBuildHomeSpecEmptyAndOfflineError() {
        let empty = CarPlayListPolicy.buildHomeSpec(.empty)
        XCTAssertEqual(empty.sections.first?.items.first?.title, "Nothing here yet")
        XCTAssertFalse(empty.sections.first?.items.contains { $0.title == "Retry" } == true)

        let offline = CarPlayListPolicy.buildHomeSpec(CarPlayListPolicy.HomeInput(
            serverError: true,
            recentTitles: ["stale"], frequentTitles: [], playlistTitles: [],
            mixTitles: [], vibeTitles: []))
        XCTAssertEqual(offline.sections.first?.items.first?.title, "Can't reach your server")
        XCTAssertTrue(offline.sections.first?.items.contains { $0.title == "Retry" } == true)

        let emptyDump = CarPlayListPolicy.dumpSpec(empty, limits: defaultLimits)
        let errorDump = CarPlayListPolicy.dumpSpec(offline, limits: defaultLimits)
        print("--- CarPlay Home dump (empty) ---\n\(emptyDump)")
        print("--- CarPlay Home dump (offline-error) ---\n\(errorDump)")
        XCTAssertTrue(emptyDump.contains("Nothing here yet"))
        XCTAssertTrue(errorDump.contains("Can't reach your server"))
        XCTAssertTrue(errorDump.contains("Retry"))
    }

    func testFixtureHomeDelegatesToBuildHomeSpec() {
        let online = CarPlayListPolicy.fixtureHome(online: true, empty: false, serverError: false)
        let viaBuilder = CarPlayListPolicy.buildHomeSpec(CarPlayListPolicy.HomeInput(
            serverError: false,
            recentTitles: ["Song A", "Album B", "Mix C", "Playlist D"],
            frequentTitles: ["Album 1", "Album 2", "Album 3"],
            playlistTitles: ["Gym", "Focus", "Road Trip"],
            mixTitles: ["Daily Mix 1", "Daily Mix 2", "Daily Mix 3"],
            vibeTitles: ["Hype", "Chill", "Feel-Good", "Focus"]))
        XCTAssertEqual(online, viaBuilder)
    }

    func testLibraryBlueprintRenamedAndCapped() {
        let library = CarPlayListPolicy.buildLibrarySpec(
            CarPlayListPolicy.LibraryInput(
                serverError: false,
                playlists: (0..<40).map {
                    CarPlayListPolicy.PlaylistRef(id: "id-\($0)", title: "Playlist \($0)")
                },
                downloadedCount: 3),
            playlistCap: 7)
        XCTAssertEqual(library.tabTitle, "Your Library")
        let clamped = CarPlayListPolicy.clamp(library.sections, limits: limitedLimits)
        XCTAssertLessThanOrEqual(
            clamped.reduce(0) { $0 + $1.items.count }, 12)
        let dump = CarPlayListPolicy.dumpSpec(library, limits: limitedLimits)
        print("--- CarPlay Library dump ---\n\(dump)")
        XCTAssertTrue(dump.contains("Your Library"))
    }

    /// Duplicate playlist titles + a playlist named like a browse shortcut must
    /// keep distinct stable ids / roles (never match Library rows by title alone).
    func testLibraryPlaylistsMatchByIdNotTitle() {
        let input = CarPlayListPolicy.LibraryInput(
            serverError: false,
            playlists: [
                .init(id: "pl-a", title: "Chill"),
                .init(id: "pl-b", title: "Chill"),
                .init(id: "pl-albums", title: "Albums"),
                .init(id: "pl-artists", title: "Artists")
            ],
            downloadedCount: 0)
        let spec = CarPlayListPolicy.buildLibrarySpec(input, playlistCap: 40)
        let browse = spec.sections.first { $0.header == "Browse" }?.items ?? []
        let playlistSection = spec.sections.first { $0.header == "Playlists" }?.items ?? []

        XCTAssertEqual(browse.map(\.role), [
            .browseDownloaded, .browseArtists, .browseAlbums, .browseTopRated, .browseGenres
        ])
        XCTAssertEqual(browse.first { $0.role == .browseAlbums }?.title, "Albums")

        XCTAssertEqual(playlistSection.count, 4)
        XCTAssertEqual(playlistSection.map(\.role), Array(repeating: .playlist, count: 4))
        XCTAssertEqual(playlistSection.map(\.id), ["pl-a", "pl-b", "pl-albums", "pl-artists"])
        XCTAssertEqual(playlistSection.map(\.title), ["Chill", "Chill", "Albums", "Artists"])

        // Title collision must not blur browse vs playlist identity.
        let albumBrowse = browse.first { $0.role == .browseAlbums }
        let albumPlaylist = playlistSection.first { $0.id == "pl-albums" }
        XCTAssertNotEqual(albumBrowse?.role, albumPlaylist?.role)
        XCTAssertEqual(albumBrowse?.title, albumPlaylist?.title)

        let byID = Dictionary(uniqueKeysWithValues: input.playlists.map { ($0.id, $0) })
        XCTAssertEqual(byID.count, 4, "IDs stay unique even when titles collide")
        for item in playlistSection {
            XCTAssertNotNil(item.id.flatMap { byID[$0] })
        }
    }

    func testSearchChooserLabels() {
        let search = CarPlayListPolicy.buildSearchChooserSpec()
        let titles = search.sections.flatMap(\.items).map(\.title)
        XCTAssertEqual(titles, ["Voice search", "Keyboard"])
        XCTAssertFalse(titles.contains(where: { $0.localizedCaseInsensitiveContains("iPhone") }))
        print("--- CarPlay Search dump ---\n\(CarPlayListPolicy.dumpSpec(search, limits: defaultLimits))")
    }

    func testNowPlayingButtonBudgets() {
        XCTAssertLessThanOrEqual(
            CarPlayListPolicy.fixtureNowPlayingMusicButtons().count, 5)
        XCTAssertFalse(
            CarPlayListPolicy.fixtureNowPlayingMusicButtons().contains("Artist"))
        XCTAssertTrue(
            CarPlayListPolicy.fixtureNowPlayingMusicButtons().contains("Rate"))
        XCTAssertLessThanOrEqual(
            CarPlayListPolicy.fixtureNowPlayingPodcastButtons().count, 5)
    }

    func testDepthPathsWithinCarPlayLimit() {
        // Drive the same pushDecision the scene delegate calls.

        // Library → Albums → A → Album → Now Playing → Up Next
        let albumsUpNext = CarPlayListPolicy.simulateNavigation(steps: [
            .browse, .letter, .detail, .nowPlaying, .upNext
        ])
        XCTAssertEqual(
            albumsUpNext.decisions,
            [.push, .push, .push, .push, .replaceTop])
        XCTAssertEqual(albumsUpNext.depth, 5)

        // Same path + queue editor — still ≤5 via replaceTop.
        let queueEditor = CarPlayListPolicy.simulateNavigation(steps: [
            .browse, .letter, .detail, .nowPlaying, .upNext, .queueEditor
        ])
        XCTAssertEqual(queueEditor.decisions.suffix(2), [.replaceTop, .replaceTop])
        XCTAssertEqual(queueEditor.depth, 5)

        // Artists → letter → artist → album (depth 5) → Now Playing skipped.
        let artistAlbumNP = CarPlayListPolicy.simulateNavigation(steps: [
            .browse, .letter, .detail, .detail, .nowPlaying
        ])
        XCTAssertEqual(
            artistAlbumNP.decisions,
            [.push, .push, .push, .push, .skip])
        XCTAssertEqual(artistAlbumNP.depth, 5)

        // Artist ↔ Album at the limit replaces top (no growth).
        XCTAssertEqual(
            CarPlayListPolicy.pushDecision(currentDepth: 5, kind: .detail),
            .replaceTop)

        // Podcast Up Next from Now Playing at depth 5.
        let podcastUpNext = CarPlayListPolicy.simulateNavigation(steps: [
            .browse, .nowPlaying, .upNext
        ])
        XCTAssertLessThanOrEqual(
            podcastUpNext.depth, CarPlayListPolicy.absoluteMaxDepth)
        XCTAssertNotEqual(
            CarPlayListPolicy.pushDecision(currentDepth: 5, kind: .upNext),
            .push)

        // In-place More… never calls pushDecision — depth stays at letter.
        let letterOnly = CarPlayListPolicy.simulateNavigation(steps: [
            .browse, .letter
        ])
        XCTAssertEqual(letterOnly.depth, 3)

        // Mirrored search Voice/Keys: pop overlay then push search (depth stays).
        XCTAssertEqual(
            CarPlayListPolicy.pushDecision(currentDepth: 2, kind: .search),
            .push)

        let paths: [[String]] = [
            ["Home"],
            ["Home", "Daily Mixes"],
            ["Your Library", "Albums", "A", "Album"],
            ["Your Library", "Artists", "B", "Artist"],
            ["Your Library", "Top Rated", "Album"],
            ["Podcasts", "Show"],
            ["Now Playing"]
        ]
        for path in paths {
            XCTAssertTrue(
                CarPlayListPolicy.assertWithinDepth(path),
                "Path too deep: \(path)")
        }
    }

    func testRatingSheetReachesOneStarAndClear() {
        XCTAssertEqual(
            CarPlayListPolicy.reachableRatings(),
            Set([0, 1, 2, 3, 4, 5]))
        let low = CarPlayListPolicy.ratingSheetActions(level: .low)
        XCTAssertTrue(low.contains(.setStars(1)))
        XCTAssertTrue(low.contains(.clear))
        XCTAssertEqual(low.count, 2)
        for level in [CarPlayListPolicy.RatingSheetLevel.high, .mid, .low] {
            XCTAssertLessThanOrEqual(
                CarPlayListPolicy.ratingSheetActions(level: level).count, 3)
        }
    }

    func testLetterBucketsKeepFullListsAndPageInPlace() {
        struct Row { let name: String }
        // Populate every letter so Limit UI (12 rows) must page the index.
        var rows: [Row] = (0..<30).map { Row(name: "A Song \($0)") }
        for scalar in UnicodeScalar("B").value...UnicodeScalar("Z").value {
            let letter = String(UnicodeScalar(scalar)!)
            rows.append(Row(name: "\(letter) Artist"))
        }
        rows.append(Row(name: "1 Numeric"))
        let buckets = CarPlayListPolicy.letterBuckets(rows, name: { $0.name })
        XCTAssertEqual(buckets.first?.letter, "A")
        XCTAssertEqual(buckets.first?.items.count, 30, "Must not truncate away unreachable items")
        XCTAssertGreaterThanOrEqual(buckets.count, 26)
        XCTAssertTrue(buckets.contains { $0.letter == "Z" }, "Late letters must remain reachable")

        // Index paging (Limit UI: 12 rows) must still reach Z via in-place More…
        var indexOffset = 0
        var seenLetters = Set<String>()
        var indexPages = 0
        while true {
            let indexPage = CarPlayListPolicy.letterPage(
                buckets, offset: indexOffset, pageSize: 11)
            indexPages += 1
            seenLetters.formUnion(indexPage.page.map(\.letter))
            guard let next = indexPage.nextOffset else { break }
            indexOffset = next
        }
        XCTAssertGreaterThan(indexPages, 1)
        XCTAssertTrue(seenLetters.contains("Z"), "In-place index More… must reach Z")

        let page = CarPlayListPolicy.letterPage(
            buckets[0].items, offset: 0, pageSize: 8)
        XCTAssertEqual(page.page.count, 8)
        XCTAssertEqual(page.nextOffset, 8)
        XCTAssertNil(page.previousOffset)

        // Simulate many in-place More… pages — stack stays at letter depth.
        var offset = 0
        var pages = 0
        var lastPrevious: Int?
        while true {
            let p = CarPlayListPolicy.letterPage(
                buckets[0].items, offset: offset, pageSize: 8)
            pages += 1
            lastPrevious = p.previousOffset
            guard let next = p.nextOffset else { break }
            offset = next
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertNotNil(lastPrevious, "Later pages must offer ← Previous")
        XCTAssertEqual(
            CarPlayListPolicy.simulateNavigation(steps: [.browse, .letter]).depth,
            3)
        let back = CarPlayListPolicy.letterPage(
            buckets[0].items, offset: lastPrevious ?? 0, pageSize: 8)
        XCTAssertFalse(back.page.isEmpty)
    }
}
