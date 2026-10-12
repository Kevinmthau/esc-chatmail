import XCTest
@testable import esc_chatmail

/// HONEST SCOPE: these pin the policy's decisions and the coordinator pins
/// their wiring (`ChatMessagesCoordinatorTests`, the tail-realization tests).
/// Whether a lazy stack actually leaves the tail unrealized after the
/// anchored jump, and whether the nudge's offset change makes it fill the
/// rect, is SwiftUI layout behaviour with no unit-test seam; that half is
/// owned by the device check the change asks for.
final class ChatTranscriptRealizationPolicyTests: XCTestCase {
    /// Revert-check: `ChatTranscriptRealizationPolicy.probeKind(isNewestRowRealized:)`
    /// returning `.bottomAnchor` for an unrealized row makes the hidden pass
    /// re-issue a `scrollTo` to the offset the pinned end already put the
    /// scroll view at, which moves nothing and realizes nothing.
    func testProbeKind_newestRowUnrealized_nudges() {
        XCTAssertEqual(
            ChatTranscriptRealizationPolicy.probeKind(isNewestRowRealized: false),
            .realizationNudge
        )
    }

    /// Revert-check: returning `.realizationNudge` for a realized row adds an
    /// offset round trip to every growth-driven probe.
    func testProbeKind_newestRowRealized_scrollsToBottomAnchor() {
        XCTAssertEqual(
            ChatTranscriptRealizationPolicy.probeKind(isNewestRowRealized: true),
            .bottomAnchor
        )
    }

    /// Revert-check: a non-nil target for a one-row window indexes past the
    /// rows (`ChatMessagesView.performBottomAnchor` subscripts the displayed
    /// rows with it).
    func testNudgeTargetIndex_fewerThanTwoRows_isNil() {
        XCTAssertNil(ChatTranscriptRealizationPolicy.nudgeTargetIndex(rowCount: 0))
        XCTAssertNil(ChatTranscriptRealizationPolicy.nudgeTargetIndex(rowCount: 1))
    }

    /// Revert-check: targeting the newest row (`rowCount - 1`) with anchor
    /// `.bottom` is the content end itself, which the scroll view clamps to
    /// the offset already in place; the nudge must land above it.
    func testNudgeTargetIndex_twoOrMoreRows_isSecondNewest() {
        XCTAssertEqual(ChatTranscriptRealizationPolicy.nudgeTargetIndex(rowCount: 2), 0)
        XCTAssertEqual(ChatTranscriptRealizationPolicy.nudgeTargetIndex(rowCount: 20), 18)
    }
}
