import XCTest

final class esc_chatmailUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
    }

    @MainActor
    func testNewMessageTitleIsSmallerInCompose() throws {
        let app = XCUIApplication()
        app.launch()

        let composeButton = app.buttons["Compose new message"]
        XCTAssertTrue(
            composeButton.waitForExistence(timeout: 10),
            "Compose button not found. Verify the simulator is signed in and showing Chats."
        )

        composeButton.tap()

        let title = app.staticTexts["New Message"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "New Message title did not appear in compose UI.")

        // iMessage-like compact title sizing should render below this frame height.
        XCTAssertLessThan(title.frame.height, 28, "Compose title is still visually too large.")
    }
}
