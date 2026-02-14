import XCTest

final class esc_chatmailUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UI_TEST_MODE", "UI_TEST_AUTHENTICATED"]
        app.launch()
        return app
    }

    private func dismissPermissionAlertsIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alertSources = [app, springboard]

        let dismissalCandidates = [
            "Don't Allow",
            "Don’t Allow",
            "Not Now",
            "Continue",
            "Allow",
            "Allow Once",
            "Allow While Using App",
            "OK"
        ]

        for _ in 0..<4 {
            var dismissedAnyAlert = false

            for source in alertSources {
                let alert = source.alerts.firstMatch
                guard alert.exists || alert.waitForExistence(timeout: 0.5) else { continue }

                for title in dismissalCandidates {
                    let button = alert.buttons[title]
                    if button.exists {
                        button.tap()
                        dismissedAnyAlert = true
                        break
                    }
                }

                if !dismissedAnyAlert, alert.buttons.firstMatch.exists {
                    alert.buttons.firstMatch.tap()
                    dismissedAnyAlert = true
                }

                if dismissedAnyAlert {
                    break
                }
            }

            if !dismissedAnyAlert { return }
        }
    }

    @MainActor
    func testAppLaunches() throws {
        _ = launchApp()
    }

    @MainActor
    func testNewMessageTitleIsSmallerInCompose() throws {
        let app = launchApp()
        dismissPermissionAlertsIfPresent(app)

        let composeButton = app.buttons["ComposeNewMessageButton"]
        XCTAssertTrue(
            composeButton.waitForExistence(timeout: 12),
            "Compose button not found. Verify the simulator is signed in and showing Chats."
        )

        if composeButton.isHittable {
            composeButton.tap()
        } else {
            composeButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        dismissPermissionAlertsIfPresent(app)

        let titleByID = app.staticTexts["ComposeTitleText"]
        let titleByLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "New Message")).firstMatch

        let hasTitle = titleByID.waitForExistence(timeout: 8) || titleByLabel.waitForExistence(timeout: 2)
        XCTAssertTrue(hasTitle, "Compose sheet did not appear.")

        let title = titleByID.exists ? titleByID : titleByLabel

        // iMessage-like compact title sizing should render below this frame height.
        XCTAssertLessThan(title.frame.height, 28, "Compose title is still visually too large.")
    }
}
