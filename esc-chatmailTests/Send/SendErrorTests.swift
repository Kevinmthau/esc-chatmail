import XCTest
@testable import esc_chatmail

/// Tests for GmailSendService error handling.
final class SendErrorTests: XCTestCase {

    // MARK: - SendError Description Tests

    func testSendError_invalidMimeData_hasDescription() {
        let error = GmailSendService.SendError.invalidMimeData
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testSendError_apiError_includesMessage() {
        let message = "Rate limit exceeded"
        let error = GmailSendService.SendError.apiError(message)

        XCTAssertEqual(error.errorDescription, message)
    }

    func testSendError_authenticationFailed_hasDescription() {
        let error = GmailSendService.SendError.authenticationFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("authentication"))
    }

    func testSendError_optimisticCreationFailed_hasDescription() {
        let error = GmailSendService.SendError.optimisticCreationFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testSendError_conversationNotFound_hasDescription() {
        let error = GmailSendService.SendError.conversationNotFound
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("conversation"))
    }

    func testSendError_replyTargetUnavailable_hasDescription() {
        let error = GmailSendService.SendError.replyTargetUnavailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("selected"))
        // Revert-check: restoring "Reopen the conversation and try again."
        // fails this; reopening could not fix a moved target.
        XCTAssertFalse(error.errorDescription!.lowercased().contains("reopen"))
    }

    /// When the chat itself moved or was removed, every message in it is
    /// unusable, so the selected-message advice would send the user around in
    /// circles.
    ///
    /// Revert-check: pointing `replyConversationUnavailable`'s description
    /// back at `replyTargetUnavailable`'s long-press copy fails this.
    func testSendError_replyConversationUnavailable_describesTheMovedChatNotTheSelection() {
        let description = GmailSendService.SendError.replyConversationUnavailable.errorDescription
        XCTAssertEqual(
            description,
            "This conversation moved while you were replying. Your draft and attachments are still here."
        )
        XCTAssertFalse(description!.lowercased().contains("long-press"))
        XCTAssertNotEqual(description, GmailSendService.SendError.replyTargetUnavailable.errorDescription)
    }

    // MARK: - Error Equality Tests

    func testSendError_apiError_differentMessages() {
        let error1 = GmailSendService.SendError.apiError("Error 1")
        let error2 = GmailSendService.SendError.apiError("Error 2")

        // Different API errors should have different descriptions
        XCTAssertNotEqual(error1.errorDescription, error2.errorDescription)
    }

    // MARK: - LocalizedError Conformance

    func testSendError_conformsToLocalizedError() {
        let errors: [GmailSendService.SendError] = [
            .invalidMimeData,
            .apiError("test"),
            .authenticationFailed,
            .optimisticCreationFailed,
            .conversationNotFound,
            .replyTargetUnavailable,
            .replyConversationUnavailable
        ]

        for error in errors {
            // LocalizedError should provide errorDescription
            XCTAssertNotNil(error.errorDescription,
                          "\(error) should have an errorDescription")
        }
    }
}
