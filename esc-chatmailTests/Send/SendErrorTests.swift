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
            .conversationNotFound
        ]

        for error in errors {
            // LocalizedError should provide errorDescription
            XCTAssertNotNil(error.errorDescription,
                          "\(error) should have an errorDescription")
        }
    }
}
