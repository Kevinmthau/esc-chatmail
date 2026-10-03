import SwiftUI
import XCTest
@testable import esc_chatmail

final class ChatTranscriptScrollAnchorPolicyTests: XCTestCase {
    /// Revert-check: returning `.top` for a hidden transcript from
    /// `ChatTranscriptScrollAnchorPolicy.sizeChanges(isTranscriptRevealed:)`
    /// lets bubble growth during the hidden anchor pass push the bottom anchor
    /// off the viewport edge again, which restarts the pass on every load.
    func testSizeChanges_transcriptHidden_pinsContentEnd() {
        XCTAssertEqual(
            ChatTranscriptScrollAnchorPolicy.sizeChanges(isTranscriptRevealed: false),
            .bottom
        )
    }

    /// Revert-check: returning `.bottom` for a revealed transcript from
    /// `ChatTranscriptScrollAnchorPolicy.sizeChanges(isTranscriptRevealed:)`
    /// breaks `ChatBottomInsetPolicy`'s premise that inset growth adds space
    /// below the viewport without moving the offset.
    func testSizeChanges_transcriptRevealed_keepsTopAnchor() {
        XCTAssertEqual(
            ChatTranscriptScrollAnchorPolicy.sizeChanges(isTranscriptRevealed: true),
            .top
        )
    }

    func testInitialOffsetAndAlignment_startAtEndAndAlignTop() {
        XCTAssertEqual(ChatTranscriptScrollAnchorPolicy.initialOffset, .bottom)
        XCTAssertEqual(ChatTranscriptScrollAnchorPolicy.alignment, .top)
    }
}
