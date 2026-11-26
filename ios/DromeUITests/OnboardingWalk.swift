import XCTest

/// Separate onboarding walk so smoke tabs aren't blocked by the tour cover.
final class OnboardingWalk: XCTestCase {
    func testOnboardingSkipAndContinueChrome() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestWalk",
            "-UITestPodcastMini",
            "-UITestShowOnboarding",
        ]
        app.launch()

        let continueBtn = app.buttons["onboarding-continue"]
        XCTAssertTrue(continueBtn.waitForExistence(timeout: 6), "Missing onboarding continue")
        // AX / default: never show cryptic "1/N" — first Continue is plain or "Continue · 1 of 5".
        let label = continueBtn.label
        XCTAssertFalse(label.contains("/"), "Continue label should not be a bare fraction: \(label)")

        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "uitest-walk-onboarding"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Skip keeps its own identifier (not swallowed by drome.onboarding.screen).
        let skip = app.buttons["drome.onboarding.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 2), "Skip accessibility id must survive parent screen id")
        skip.tap()

        XCTAssertTrue(app.buttons["drome.tab.home"].waitForExistence(timeout: 6))
    }
}
