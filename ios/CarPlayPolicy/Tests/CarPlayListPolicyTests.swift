import XCTest
@testable import CarPlayListPolicy

/// Headless verification of CarPlay template blueprints (online / empty / offline).
/// Run via `ios/scripts/test-carplay-policy.sh` — no CarPlay Simulator required.
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
        // Image-row rails must not duplicate the row title as a section header.
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
                playlistTitles: (0..<40).map { "Playlist \($0)" },
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
        let paths: [[String]] = [
            ["Home"],
            ["Home", "Daily Mixes"],
            ["Your Library", "Albums", "A", "Album"],
            ["Your Library", "Albums", "A", "More…", "Album"],
            ["Your Library", "Top Rated", "Album"],
            ["Your Library", "Artists", "B", "Artist"],
            ["Your Library", "Artists", "B", "More…", "Artist"],
            ["Podcasts", "Show"],
            ["Now Playing", "Rate"]
        ]
        for path in paths {
            XCTAssertTrue(
                CarPlayListPolicy.assertWithinDepth(path),
                "Path too deep: \(path)")
        }
    }

    func testLetterBucketsKeepFullListsAndPageWithMore() {
        struct Row { let name: String }
        let rows = (0..<30).map { Row(name: "A Song \($0)") }
            + (0..<5).map { Row(name: "B Track \($0)") }
            + [Row(name: "1 Numeric")]
        let buckets = CarPlayListPolicy.letterBuckets(
            rows, name: { $0.name }, maxLetters: 5)
        XCTAssertEqual(buckets.first?.letter, "A")
        XCTAssertEqual(buckets.first?.items.count, 30, "Must not truncate away unreachable items")

        let page = CarPlayListPolicy.letterPage(
            buckets[0].items, offset: 0, pageSize: 8)
        XCTAssertEqual(page.page.count, 8)
        XCTAssertEqual(page.nextOffset, 8)
        XCTAssertEqual(page.remaining, 22)

        let rest = CarPlayListPolicy.letterPage(
            buckets[0].items, offset: 24, pageSize: 8)
        XCTAssertEqual(rest.page.count, 6)
        XCTAssertNil(rest.nextOffset)
    }
}
