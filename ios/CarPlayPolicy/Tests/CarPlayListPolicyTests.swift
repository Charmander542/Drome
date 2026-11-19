import XCTest
@testable import CarPlayListPolicy

final class CarPlayListPolicyTests: XCTestCase {
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
    }

    func testOnlineHomeFixtureStaysUnderLimits() {
        let limits = CarPlayListPolicy.Limits(
            maxSections: 8, maxItems: 12, listsLimited: true)
        let home = CarPlayListPolicy.fixtureHome(online: true, empty: false, serverError: false)
        let clamped = CarPlayListPolicy.clamp(home.sections, limits: limits)
        XCTAssertLessThanOrEqual(clamped.count, limits.maxSections)
        XCTAssertLessThanOrEqual(
            clamped.reduce(0) { $0 + $1.items.count }, limits.maxItems)
        XCTAssertTrue(clamped.contains { $0.header == "Quick Play" })
        XCTAssertTrue(clamped.flatMap(\.items).contains { $0.title == "Shuffle All" })
        XCTAssertTrue(clamped.flatMap(\.items).contains { $0.isImageRow })
    }

    func testServerErrorDistinctFromEmpty() {
        let errorHome = CarPlayListPolicy.fixtureHome(
            online: false, empty: false, serverError: true)
        let emptyHome = CarPlayListPolicy.fixtureHome(
            online: true, empty: true, serverError: false)
        XCTAssertEqual(errorHome.sections.first?.items.first?.title, "Can't reach your server")
        XCTAssertTrue(errorHome.sections.first?.items.contains { $0.title == "Retry" } == true)
        XCTAssertEqual(emptyHome.sections.first?.items.first?.title, "Nothing here yet")
        XCTAssertFalse(emptyHome.sections.first?.items.contains { $0.title == "Retry" } == true)
    }

    func testLibraryFixtureRenamedAndCapped() {
        let limits = CarPlayListPolicy.Limits(
            maxSections: 4, maxItems: 12, listsLimited: true)
        let library = CarPlayListPolicy.fixtureLibrary(serverError: false, playlistCount: 40)
        XCTAssertEqual(library.tabTitle, "Your Library")
        let clamped = CarPlayListPolicy.clamp(library.sections, limits: limits)
        XCTAssertLessThanOrEqual(
            clamped.reduce(0) { $0 + $1.items.count }, 12)
    }

    func testSearchChooserLabels() {
        let search = CarPlayListPolicy.fixtureSearchChooser()
        let titles = search.sections.flatMap(\.items).map(\.title)
        XCTAssertEqual(titles, ["Voice search", "Keyboard"])
        XCTAssertFalse(titles.contains(where: { $0.localizedCaseInsensitiveContains("iPhone") }))
    }

    func testNowPlayingButtonBudgets() {
        XCTAssertLessThanOrEqual(
            CarPlayListPolicy.fixtureNowPlayingMusicButtons().count, 5)
        XCTAssertFalse(
            CarPlayListPolicy.fixtureNowPlayingMusicButtons().contains("Artist"))
        XCTAssertLessThanOrEqual(
            CarPlayListPolicy.fixtureNowPlayingPodcastButtons().count, 5)
    }

    func testDepthPathsWithinCarPlayLimit() {
        let paths: [[String]] = [
            ["Home"],
            ["Home", "Daily Mixes"],
            ["Your Library", "Albums", "A", "Album"],
            ["Your Library", "Top Rated", "Album"],
            ["Your Library", "Artists", "B", "Artist"],
            ["Podcasts", "Show", "Episode play → NP"]
        ]
        for path in paths {
            XCTAssertLessThanOrEqual(
                CarPlayListPolicy.depth(for: path),
                CarPlayListPolicy.absoluteMaxDepth,
                "Path too deep: \(path)")
            XCTAssertLessThanOrEqual(
                CarPlayListPolicy.depth(for: path),
                CarPlayListPolicy.preferredMaxDepth + 1)
        }
    }

    func testLetterBucketsSortedAndCapped() {
        struct Row { let name: String }
        let rows = (0..<30).map { Row(name: "A Song \($0)") }
            + (0..<5).map { Row(name: "B Track \($0)") }
            + [Row(name: "1 Numeric")]
        let buckets = CarPlayListPolicy.letterBuckets(
            rows, name: { $0.name }, maxPerLetter: 10, maxLetters: 5)
        XCTAssertEqual(buckets.first?.letter, "A")
        XCTAssertEqual(buckets.first?.items.count, 10)
        XCTAssertTrue(buckets.contains { $0.letter == "#" })
    }

    func testDumpSpecProducesReadableText() {
        let limits = CarPlayListPolicy.Limits(
            maxSections: 8, maxItems: 20, listsLimited: false)
        let home = CarPlayListPolicy.fixtureHome(online: true, empty: false, serverError: false)
        // Mirror DEBUG dump formatting without importing CarPlay.
        let clamped = CarPlayListPolicy.clamp(home.sections, limits: limits)
        var lines: [String] = ["tab=\(home.tabTitle ?? home.title)"]
        for section in clamped {
            lines.append("section \(section.header ?? "-") items=\(section.items.count)")
            for item in section.items {
                lines.append("  \(item.title) img=\(item.hasImage) tiles=\(item.imageRowTitles?.count ?? 0)")
            }
        }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Quick Play"))
        XCTAssertTrue(text.contains("Shuffle All"))
        XCTAssertTrue(text.contains("Daily Mixes") || text.contains("Vibe Tuner"))
    }
}
