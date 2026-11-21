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
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "uitest-walk-onboarding"
        attachment.lifetime = .keepAlways
        add(attachment)

        let skip = app.buttons["drome.onboarding.skip"]
        XCTAssertTrue(skip.exists)
        skip.tap()

        XCTAssertTrue(app.buttons["drome.tab.home"].waitForExistence(timeout: 6))
    }
}
