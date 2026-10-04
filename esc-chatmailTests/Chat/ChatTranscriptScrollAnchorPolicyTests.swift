import SwiftUI
import XCTest
@testable import esc_chatmail

/// HONEST SCOPE: these pin the policy's decisions only. The view wiring that
/// applies them (`ChatTranscriptScrollAnchors` in `ChatMessagesView`, keyed on
/// `coordinator.isReadyToShow`) is SwiftUI modifier state with no unit-test
/// seam, so dropping that modifier, passing `isTranscriptRevealed: true`
/// unconditionally, or keying it on the view's loaded-and-revealed
/// `isTranscriptRevealed` keeps this suite green while the slow open (or, for
/// the last, the row-less `.bottom` anchor) returns. That half is owned by the
/// simulator or device check the change asks for.
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

    /// Revert-check: a `.top` `ChatTranscriptScrollAnchorPolicy.initialOffset`
    /// lands a window that is already published on the scroll view's first
    /// layout at its oldest rows.
    func testInitialOffset_firstLayout_startsAtContentEnd() {
        XCTAssertEqual(ChatTranscriptScrollAnchorPolicy.initialOffset, .bottom)
    }

    /// Revert-check: `ChatTranscriptScrollAnchorPolicy.alignment` is inert
    /// while `ChatMessagesView` floors the content at the viewport height;
    /// pinned to `.top`, the single anchor the transcript used before the
    /// roles were split, so a change to it is deliberate, not incidental.
    func testAlignment_contentShorterThanViewport_keepsTop() {
        XCTAssertEqual(ChatTranscriptScrollAnchorPolicy.alignment, .top)
    }
}
