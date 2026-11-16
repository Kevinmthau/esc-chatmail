import XCTest
@testable import esc_chatmail

/// The words on the app's message fields (`MessageFieldPolicy`).
final class MessageFieldPolicyTests: XCTestCase {
    /// The word is Kevin's choice (PR 430); the fields said "iMessage" before it.
    ///
    /// Revert-check: setting `MessageFieldPolicy.placeholder` to "iMessage" makes this fail.
    func testPlaceholder_isEmail() {
        XCTAssertEqual(MessageFieldPolicy.placeholder, "Email")
    }

    /// The compose sheet that has a Subject field said "Message" in its empty body while
    /// every other message field said the word.
    ///
    /// Revert-check: returning "Message" for `isForward: false` from
    /// `composeBodyPlaceholder` makes the first assertion fail; returning `placeholder`
    /// whatever `isForward` says makes the second fail.
    func testComposeBodyPlaceholder_isTheFieldsWord_exceptOnAForward() {
        XCTAssertEqual(
            MessageFieldPolicy.composeBodyPlaceholder(isForward: false),
            MessageFieldPolicy.placeholder
        )
        XCTAssertEqual(
            MessageFieldPolicy.composeBodyPlaceholder(isForward: true),
            "Add a message (optional)"
        )
    }
}
