import XCTest
@testable import esc_chatmail

final class ChatConversationExitActionPolicyTests: XCTestCase {
    private typealias Policy = ChatConversationExitActionPolicy

    private func releaseDecision(
        release: Policy.SendRelease = .replyPersisted,
        accountIsUnchanged: Bool = true,
        conversationIsAvailable: Bool = true,
        presentation: Policy.Presentation = .onScreen
    ) -> Policy.ReleaseDecision {
        Policy.releaseDecision(
            release: release,
            accountIsUnchanged: accountIsUnchanged,
            conversationIsAvailable: conversationIsAvailable,
            presentation: presentation
        )
    }

    /// The menu stays enabled while a reply holds the composer; a tap made then used to be
    /// dropped without a word by the action-time guard.
    ///
    /// Revert-check: returning `.performNow` regardless of `isSending` in
    /// `ChatConversationExitActionPolicy.tapDecision` fails this test.
    func testTapDecision_whileReplyHoldsComposer_defersInsteadOfDropping() {
        XCTAssertEqual(Policy.tapDecision(isSending: true), .deferUntilSendReleases)
        XCTAssertEqual(Policy.tapDecision(isSending: false), .performNow)
    }

    /// Once the optimistic message is durable the reply is owned by its graph, as for any tap
    /// made a moment later: run the action, and leave the chat only if it is still on screen.
    func testReleaseDecision_replyPersisted_performs() {
        XCTAssertEqual(releaseDecision(presentation: .onScreen), .performAndDismiss)
        XCTAssertEqual(releaseDecision(presentation: .left), .performWithoutDismissing)
    }

    /// The reply came back to the composer (with an alert) or into the stored draft. Archiving
    /// would dismiss the alert and bury the unsent reply in an archived or spam conversation.
    ///
    /// Revert-check: deleting the `release == .replyPersisted` guard from
    /// `ChatConversationExitActionPolicy.releaseDecision` fails this test.
    func testReleaseDecision_replyReturned_drops() {
        XCTAssertEqual(releaseDecision(release: .replyReturned, presentation: .onScreen), .drop(.replyReturned))
        XCTAssertEqual(releaseDecision(release: .replyReturned, presentation: .left), .drop(.replyReturned))
    }

    /// Opening the chat again after the tap is the user's newer choice; archiving the
    /// conversation under the reopened screen would contradict it.
    ///
    /// Revert-check: performing for `.reopened` in
    /// `ChatConversationExitActionPolicy.releaseDecision` fails this test.
    func testReleaseDecision_chatReopenedSinceTap_drops() {
        XCTAssertEqual(releaseDecision(presentation: .reopened), .drop(.chatReopened))
    }

    /// Nothing is left to act on: another account's store, or a deleted or drained conversation.
    func testReleaseDecision_accountChangedOrConversationGone_drops() {
        XCTAssertEqual(releaseDecision(accountIsUnchanged: false), .drop(.accountChanged))
        XCTAssertEqual(releaseDecision(conversationIsAvailable: false), .drop(.conversationUnavailable))
        XCTAssertEqual(
            releaseDecision(release: .replyReturned, accountIsUnchanged: false, presentation: .reopened),
            .drop(.accountChanged)
        )
    }
}
