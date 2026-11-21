import XCTest

/// Tree-driven smoke + chrome walk. Loads DecisionTree.json, exercises tabs,
/// Settings tiles, Library filters, Search chips, music + podcast Now Playing
/// controls, then attaches PNGs for agent review.
final class DecisionTreeWalk: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += [
            "-UITestWalk",
            "-UITestPodcastMini",
        ]
        app.launch()
    }

    /// Fast tab circuit — used by CI / quick checks.
    func testSmokeTabCircuit() throws {
        skipOnboardingIfNeeded()

        let tabs: [(String, String)] = [
            ("drome.tab.home", "home"),
            ("drome.tab.search", "search"),
            ("drome.tab.library", "library"),
            ("drome.tab.podcasts", "podcasts"),
            ("drome.tab.home", "home-return"),
        ]

        for (id, shot) in tabs {
            tapButton(id, timeout: 6)
            assertExists(id)
            capture(shot)
        }
    }

    /// Broader walk: Settings tiles, Library filters, Search chips, music NP
    /// transport / options, Podcasts mini → NP.
    func testFullChromeWalk() throws {
        skipOnboardingIfNeeded()

        walkHomeAndSettings()
        walkSearchFilters()
        walkLibraryFiltersAndHandoffs()
        walkMusicNowPlaying()
        walkPodcasts()

        tapButton("drome.tab.home")
        assertExists("drome.home.settings")
        // Vibe play is present when Home renders the tuner (offline empty state still has it).
        _ = app.buttons["drome.home.vibe-play"].waitForExistence(timeout: 3)
        capture("home-final")
    }

    func testDecisionTreeCriticalNodesExist() throws {
        let tree = try DecisionTreeLoader.load()
        let critical = tree.nodes.filter { $0.priority == "critical" }
        XCTAssertFalse(critical.isEmpty)

        var missing: [String] = []
        for node in critical {
            guard let a11y = node.a11y, !a11y.isEmpty else { continue }
            let shellIDs = [
                "drome.tab.home", "drome.tab.search",
                "drome.tab.library", "drome.tab.podcasts",
            ]
            guard shellIDs.contains(a11y) else { continue }
            let el = app.descendants(matching: .any)[a11y]
            if !el.waitForExistence(timeout: 5) {
                missing.append(a11y)
            }
        }
        if !missing.isEmpty {
            XCTFail("Missing critical a11y IDs: \(missing.joined(separator: ", "))")
        }
    }

    // MARK: - Walk sections

    private func walkHomeAndSettings() {
        tapButton("drome.tab.home")
        assertExists("drome.home.settings")
        assertExists("drome.home.vibe-play")
        capture("home")

        tapButton("drome.home.settings")
        assertExists("drome.settings.screen", timeout: 5)
        assertExists("drome.settings.accent", timeout: 3)
        capture("settings")

        // Downloads tile → Downloads list
        tapButton("drome.settings.tile.downloads")
        assertExists("drome.downloads.screen", timeout: 5)
        capture("settings-downloads")
        navigateBackOrSwipe()

        // Diagnostics tile
        tapButton("drome.settings.tile.diagnostics")
        assertExists("drome.diagnostics.screen", timeout: 5)
        capture("settings-diagnostics")
        navigateBackOrSwipe()

        // Online / Scan are action tiles (should not crash).
        tapIfExists("drome.settings.tile.online")
        capture("settings-online-tapped")
        tapIfExists("drome.settings.tile.scan")
        capture("settings-scan-tapped")

        capture("settings-after-tiles")
        dismissSettings()
    }

    private func walkSearchFilters() {
        tapButton("drome.tab.search")
        capture("search")

        guard activateSearchField() else {
            XCTFail("Search field missing")
            return
        }
        let searchField = app.searchFields.firstMatch
        searchField.typeText("a")

        for filter in ["all", "songs", "albums", "artists", "lyrics"] {
            let id = "search-filter-\(filter)"
            let chip = app.buttons[id]
            if chip.waitForExistence(timeout: 2), chip.isHittable {
                chip.tap()
                capture("search-\(filter)")
            }
        }

        if searchField.buttons["Clear text"].exists {
            searchField.buttons["Clear text"].tap()
        } else if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        } else {
            app.swipeDown()
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func walkLibraryFiltersAndHandoffs() {
        tapButton("drome.tab.library")
        capture("library")

        for filter in ["playlists", "artists", "albums", "songs", "genres"] {
            let id = "drome.library.filter.\(filter)"
            let chip = app.buttons[id]
            if chip.waitForExistence(timeout: 2), chip.isHittable {
                chip.tap()
                capture("library-\(filter)")
            }
        }

        tapIfExists("drome.library.top-rated")
        if app.navigationBars["4 Stars & Up"].waitForExistence(timeout: 3)
            || app.staticTexts["4 Stars & Up"].waitForExistence(timeout: 1) {
            capture("library-top-rated")
            navigateBackOrSwipe()
        }

        for id in ["library-songs-search-button", "library-albums-search-button", "library-artists-search-button"] {
            let btn = app.buttons[id]
            if btn.waitForExistence(timeout: 2) {
                btn.tap()
                capture("library-handoff-\(id)")
                tapButton("drome.tab.library")
            }
        }
    }

    private func walkMusicNowPlaying() {
        // Leave any pushed Library screen so mini chrome is hittable.
        tapButton("drome.tab.home")
        Thread.sleep(forTimeInterval: 0.3)

        // Podcast chrome wins by default — flip to music mini for NP controls.
        tapIfExists("drome.uitest.show-music")
        Thread.sleep(forTimeInterval: 0.6)

        let musicOpen = app.descendants(matching: .any)["drome.music.mini.open"]
        let musicMini = app.descendants(matching: .any)["music-mini-player"]
        if musicOpen.waitForExistence(timeout: 4) {
            musicOpen.tap()
        } else if musicMini.waitForExistence(timeout: 3) {
            // Tap left side (artwork / title) — not the pause/next controls.
            musicMini.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        } else {
            capture("music-mini-missing")
            return
        }

        let np = app.descendants(matching: .any)["drome.nowplaying.screen"]
        guard np.waitForExistence(timeout: 6) else {
            capture("music-now-playing-missing")
            return
        }
        capture("music-now-playing")

        // Transport
        tapIfExists("drome.nowplaying.transport.play")
        capture("music-np-play-pause")

        // Pane tabs (Song / Lyrics)
        for tab in ["song", "lyrics"] {
            let id = "drome.nowplaying.tab.\(tab)"
            if app.buttons[id].waitForExistence(timeout: 1.5) {
                app.buttons[id].tap()
                capture("music-np-tab-\(tab)")
            }
        }

        // Bottom bar actions (open + dismiss sheets)
        tapIfExists("drome.nowplaying.queue")
        if app.descendants(matching: .any)["drome.queue.screen"].waitForExistence(timeout: 3) {
            capture("music-np-queue")
            dismissSheet()
        }

        tapIfExists("drome.nowplaying.sleep")
        capture("music-np-sleep")
        dismissSheet()

        tapIfExists("drome.nowplaying.add-playlist")
        capture("music-np-add-playlist")
        dismissSheet()

        // EQ on the player chrome
        tapIfExists("drome.nowplaying.eq")
        if app.descendants(matching: .any)["drome.equalizer.screen"].waitForExistence(timeout: 4) {
            capture("music-np-equalizer")
            dismissSheet()
        }

        // Dismiss NP
        app.swipeDown()
        Thread.sleep(forTimeInterval: 0.45)
        capture("home-after-music-np")
    }

    private func walkPodcasts() {
        // Restore podcast mini chrome.
        tapIfExists("drome.uitest.show-podcast")
        Thread.sleep(forTimeInterval: 0.5)

        tapButton("drome.tab.podcasts")
        capture("podcasts")

        let podcastSearch = app.buttons["podcasts-search-button"]
        if podcastSearch.waitForExistence(timeout: 3) {
            podcastSearch.tap()
            capture("podcasts-search-handoff")
            tapButton("drome.tab.podcasts")
        }

        let open = app.descendants(matching: .any)["drome.podcast.mini.open"]
        let podcastMini = app.descendants(matching: .any)["podcast-mini-player"]
        if open.waitForExistence(timeout: 4) {
            capture("podcast-mini")
            open.tap()
        } else if podcastMini.waitForExistence(timeout: 3) {
            capture("podcast-mini")
            podcastMini.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        } else {
            capture("podcast-mini-missing")
            return
        }

        let podcastNP = app.descendants(matching: .any)["drome.podcast.nowplaying.screen"]
        if podcastNP.waitForExistence(timeout: 6) {
            capture("podcast-now-playing")
            // Soft-tap play if present.
            let play = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Play")).firstMatch
            let pause = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Pause")).firstMatch
            if pause.exists { pause.tap(); capture("podcast-np-pause") }
            else if play.exists { play.tap(); capture("podcast-np-play") }
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.4)
            capture("podcasts-after-np")
        } else {
            capture("podcast-now-playing-missing")
            app.swipeDown()
        }
    }

    // MARK: - Helpers

    private func skipOnboardingIfNeeded() {
        let skip = app.buttons["drome.onboarding.skip"]
        if skip.waitForExistence(timeout: 3) {
            capture("onboarding")
            skip.tap()
        }
    }

    private func tapButton(_ id: String, timeout: TimeInterval = 5) {
        let tab = app.buttons[id]
        XCTAssertTrue(tab.waitForExistence(timeout: timeout), "Missing button \(id)")
        tab.tap()
    }

    private func tapIfExists(_ id: String, timeout: TimeInterval = 2) {
        let btn = app.buttons[id]
        if btn.waitForExistence(timeout: timeout), btn.isHittable {
            btn.tap()
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func assertExists(_ id: String, timeout: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line) {
        let el = app.descendants(matching: .any)[id]
        XCTAssertTrue(el.waitForExistence(timeout: timeout), "Missing element \(id)", file: file, line: line)
        // Soft size check — zero frames mean the control is in the tree but not laid out.
        if el.exists {
            let frame = el.frame
            if frame.width < 1 || frame.height < 1 {
                XCTFail("Element \(id) has empty frame \(frame)", file: file, line: line)
            }
        }
    }

    private func navigateBackOrSwipe() {
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout: 2), back.isHittable {
            back.tap()
            Thread.sleep(forTimeInterval: 0.35)
            return
        }
        app.swipeDown()
        Thread.sleep(forTimeInterval: 0.35)
    }

    private func dismissSettings() {
        let close = app.buttons["drome.settings.close"]
        if close.waitForExistence(timeout: 2), close.isHittable {
            close.tap()
        } else {
            dragSheetDown()
        }
        let settings = app.descendants(matching: .any)["drome.settings.screen"]
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: settings)
        _ = XCTWaiter.wait(for: [gone], timeout: 4)
        if settings.exists {
            dragSheetDown()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(settings.exists, "Settings sheet still presented")
    }

    private func dismissSheet() {
        dragSheetDown()
        if app.descendants(matching: .any)["drome.equalizer.screen"].exists
            || app.descendants(matching: .any)["drome.queue.screen"].exists
            || app.descendants(matching: .any)["drome.nowplaying.more.sheet"].exists {
            dragSheetDown()
        }
    }

    private func dragSheetDown() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        start.press(forDuration: 0.08, thenDragTo: end)
        Thread.sleep(forTimeInterval: 0.45)
    }

    /// Focus the SwiftUI `.searchable` field (may start as a non-searchField).
    @discardableResult
    private func activateSearchField() -> Bool {
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 2) {
            field.tap()
            return true
        }
        // Drawer searchable often exposes the prompt before becoming a search field.
        let prompts = [
            "Artists, songs, albums…",
            "Artists, songs, albums...",
            "Search",
        ]
        for prompt in prompts {
            let el = app.descendants(matching: .any)[prompt]
            if el.waitForExistence(timeout: 1), el.isHittable {
                el.tap()
                if app.searchFields.firstMatch.waitForExistence(timeout: 2) {
                    return true
                }
            }
        }
        // Last resort: tap upper search chrome.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14)).tap()
        return app.searchFields.firstMatch.waitForExistence(timeout: 2)
    }

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "uitest-walk-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let data = shot.pngRepresentation
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("uitest-walk", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

// MARK: - Tree loader

struct DecisionTreeFile: Decodable {
    var version: Int
    var nodes: [DecisionTreeNode]
}

struct DecisionTreeNode: Decodable {
    var id: String
    var title: String
    var kind: String
    var a11y: String?
    var priority: String
    var status: String
}

enum DecisionTreeLoader {
    static func load() throws -> DecisionTreeFile {
        let bundle = Bundle(for: DecisionTreeWalk.self)
        if let url = bundle.url(forResource: "DecisionTree", withExtension: "json") {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(DecisionTreeFile.self, from: data)
        }
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("DecisionTree.json")
        let data = try Data(contentsOf: src)
        return try JSONDecoder().decode(DecisionTreeFile.self, from: data)
    }
}
