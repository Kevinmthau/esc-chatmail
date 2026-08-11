import XCTest
@testable import esc_chatmail

@MainActor
final class ChatReplyBarTests: XCTestCase {
    func testRemovedAttachmentPlaceholderSkipsOnlyThatImport() {
        XCTAssertEqual(
            AttachmentImportFinalizationResult.resolve(
                didFinalize: false,
                generationIsActive: true
            ),
            .placeholderRemoved
        )
    }

    func testCancelledAttachmentImportStopsTheBatch() {
        XCTAssertEqual(
            AttachmentImportFinalizationResult.resolve(
                didFinalize: false,
                generationIsActive: false
            ),
            .cancelled
        )
    }

    func testFinalizedAttachmentContinuesTheBatch() {
        XCTAssertEqual(
            AttachmentImportFinalizationResult.resolve(
                didFinalize: true,
                generationIsActive: false
            ),
            .finalized
        )
    }

    func testSendIsDisabledWhileSelectedAttachmentIsStillProcessing() {
        XCTAssertFalse(
            ChatReplyBar.isSendEnabled(
                replyText: "Ready to send",
                hasAttachments: false,
                isSending: false,
                isProcessingAttachments: true
            )
        )
    }

    func testSendIsEnabledAfterSelectedAttachmentFinishesProcessing() {
        XCTAssertTrue(
            ChatReplyBar.isSendEnabled(
                replyText: "Ready to send",
                hasAttachments: false,
                isSending: false,
                isProcessingAttachments: false
            )
        )
    }

    func testSendIsDisabledWhileReplyPreflightIsActive() {
        XCTAssertFalse(
            ChatReplyBar.isSendEnabled(
                replyText: "Ready to send",
                hasAttachments: false,
                isSending: true,
                isProcessingAttachments: false
            )
        )
    }
}
