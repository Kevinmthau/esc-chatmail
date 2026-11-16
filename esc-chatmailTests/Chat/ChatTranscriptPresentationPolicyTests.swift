import XCTest
@testable import esc_chatmail

/// HONEST SCOPE: these pin the policy's decisions only. `ChatMessagesView`
/// applying them is SwiftUI state with no unit-test seam: a view that passed
/// the scroll anchors `isRevealedForInsetChanges`, gated the rows on the
/// wrong reading, reported the wrong `InitialAnchorHoldEvent`, or stopped
/// calling the policy at all keeps this suite green. That half is owned by a
/// simulator or device check.
final class ChatTranscriptPresentationPolicyTests: XCTestCase {
    private typealias Policy = ChatTranscriptPresentationPolicy
    private typealias Phase = VirtualScrollState.InitialLoadPhase

    private static let allPhases: [Phase] = [.loading, .loaded, .empty, .failed]

    private struct State {
        let phase: Phase
        let isReadyToShow: Bool
        let hasDisplayedRows: Bool

        var label: String {
            "phase=\(phase) ready=\(isReadyToShow) rows=\(hasDisplayedRows)"
        }
    }

    private static var allStates: [State] {
        allPhases.flatMap { phase in
            [false, true].flatMap { isReadyToShow in
                [false, true].map { hasDisplayedRows in
                    State(
                        phase: phase,
                        isReadyToShow: isReadyToShow,
                        hasDisplayedRows: hasDisplayedRows
                    )
                }
            }
        }
    }

    private func presentation(_ state: State) -> Policy.Presentation {
        Policy.presentation(
            initialLoadPhase: state.phase,
            isReadyToShow: state.isReadyToShow,
            hasDisplayedRows: state.hasDisplayedRows
        )
    }

    // MARK: - Presentation

    /// The hidden anchor pass: rows are published and not yet revealed.
    ///
    /// Revert-check: gating `scrollViewTakesTouches` on `isReadyToShow` in
    /// `ChatTranscriptPresentationPolicy.presentation` takes away the drag
    /// that reveals a pass which is taking long; returning `isReadyToShow ||
    /// hasDisplayedRows` for `rowsTakeTouches` lets a tap open a bubble under
    /// the cover.
    func testPresentation_hiddenAnchorPass_coversRowsAndKeepsOnlyTheScrollGesture() {
        let result = presentation(
            State(phase: .loaded, isReadyToShow: false, hasDisplayedRows: true)
        )

        XCTAssertEqual(
            result,
            Policy.Presentation(
                coversTranscript: true,
                isWaitingForInitialAnchor: true,
                scrollViewTakesTouches: true,
                rowsTakeTouches: false,
                anchorsTreatTranscriptAsRevealed: false,
                isRevealedForInsetChanges: false
            )
        )
    }

    /// Revert-check: any reading in
    /// `ChatTranscriptPresentationPolicy.presentation` that stays closed for
    /// a loaded, revealed transcript with rows (a cover that also waits on
    /// something else, a touch gate keyed on the wrong signal) fails here.
    func testPresentation_revealedWithRows_uncoversAndOpensEverything() {
        let result = presentation(
            State(phase: .loaded, isReadyToShow: true, hasDisplayedRows: true)
        )

        XCTAssertEqual(
            result,
            Policy.Presentation(
                coversTranscript: false,
                isWaitingForInitialAnchor: false,
                scrollViewTakesTouches: true,
                rowsTakeTouches: true,
                anchorsTreatTranscriptAsRevealed: true,
                isRevealedForInsetChanges: true
            )
        )
    }

    /// A revealed transcript that has no rows (`.empty`, `.failed`, or
    /// `.loading` again after an empty reveal) is where the scroll anchors
    /// and the inset shift read "revealed" differently.
    ///
    /// Revert-check: returning `isRevealedForInsetChanges` (loaded and
    /// revealed) for `anchorsTreatTranscriptAsRevealed` in
    /// `ChatTranscriptPresentationPolicy.presentation` pins the content end
    /// in these states, which parked a chat emptied while open past its
    /// content end.
    func testPresentation_revealedWithoutRows_keepsRevealedAnchorsWithoutInsetShift() {
        for phase in [Phase.loading, .empty, .failed] {
            let result = presentation(
                State(phase: phase, isReadyToShow: true, hasDisplayedRows: false)
            )

            XCTAssertTrue(result.anchorsTreatTranscriptAsRevealed, "phase=\(phase)")
            XCTAssertFalse(result.isRevealedForInsetChanges, "phase=\(phase)")
            XCTAssertTrue(result.coversTranscript, "phase=\(phase)")
            XCTAssertFalse(result.isWaitingForInitialAnchor, "phase=\(phase)")
            XCTAssertFalse(result.scrollViewTakesTouches, "phase=\(phase)")
        }
    }

    /// A window that has not loaded is covered whatever else is true, and
    /// the placeholder for the anchor pass is asked for only by rows the
    /// pass has not revealed.
    ///
    /// Revert-check: dropping `initialLoadPhase != .loaded` from
    /// `coversTranscript` in `ChatTranscriptPresentationPolicy.presentation`
    /// shows an empty scroll view in place of the loading, empty and failed
    /// overlays; making `isWaitingForInitialAnchor` ignore `hasDisplayedRows`
    /// shows the placeholder over a conversation with nothing to anchor.
    func testPresentation_everyState_coverAndPlaceholderFollowPhaseAndUnrevealedRows() {
        for state in Self.allStates {
            let result = presentation(state)
            let hasUnrevealedRows = !state.isReadyToShow && state.hasDisplayedRows

            XCTAssertEqual(
                result.coversTranscript,
                state.phase != .loaded || hasUnrevealedRows,
                state.label
            )
            XCTAssertEqual(result.isWaitingForInitialAnchor, hasUnrevealedRows, state.label)
            XCTAssertEqual(result.scrollViewTakesTouches, state.phase == .loaded, state.label)
        }
    }

    /// Nothing under the cover can be tapped: a row needs both gates open.
    ///
    /// Revert-check: opening either gate early in
    /// `ChatTranscriptPresentationPolicy.presentation` (`scrollViewTakesTouches:
    /// true` for every phase, or `rowsTakeTouches: true` during the hidden
    /// pass) makes a covered state reachable by a tap.
    func testPresentation_everyState_coveredRowIsNeverTouchable() {
        for state in Self.allStates {
            let result = presentation(state)
            guard result.coversTranscript else { continue }

            XCTAssertFalse(
                result.scrollViewTakesTouches && result.rowsTakeTouches,
                state.label
            )
        }
    }

    /// `ChatBottomInsetPolicy` plans a shift only where the transcript has
    /// its `.top` size-change anchor.
    ///
    /// Revert-check: dropping `isReadyToShow` from `isRevealedForInsetChanges`
    /// in `ChatTranscriptPresentationPolicy.presentation` makes a shift
    /// available during the hidden pass, under the pinned content end.
    func testPresentation_everyState_insetRevealImpliesRevealedAnchors() {
        for state in Self.allStates {
            let result = presentation(state)

            XCTAssertEqual(
                result.isRevealedForInsetChanges,
                state.phase == .loaded && state.isReadyToShow,
                state.label
            )
            if result.isRevealedForInsetChanges {
                XCTAssertTrue(result.anchorsTreatTranscriptAsRevealed, state.label)
            }
        }
    }

    // MARK: - Bottom anchor visibility

    private func isBottomAnchorVisibleForFollowing(
        phase: Phase = .loaded,
        isReadyToShow: Bool = true,
        isUserScrollGestureActive: Bool = false,
        isUserScrollTakeoverActive: Bool = false,
        isBottomAnchorInViewport: Bool = true
    ) -> Bool {
        Policy.isBottomAnchorVisibleForFollowing(
            initialLoadPhase: phase,
            isReadyToShow: isReadyToShow,
            isUserScrollGestureActive: isUserScrollGestureActive,
            isUserScrollTakeoverActive: isUserScrollTakeoverActive,
            isBottomAnchorInViewport: isBottomAnchorInViewport
        )
    }

    /// Revert-check: any further condition added to
    /// `ChatTranscriptPresentationPolicy.isBottomAnchorVisibleForFollowing`
    /// that a revealed transcript resting at its bottom does not meet stops
    /// the chat following new messages.
    func testBottomAnchorVisibleForFollowing_revealedAtRestWithAnchorInViewport_isTrue() {
        XCTAssertTrue(isBottomAnchorVisibleForFollowing())
    }

    /// Revert-check: dropping `isReadyToShow` from
    /// `ChatTranscriptPresentationPolicy.isBottomAnchorVisibleForFollowing`
    /// marks mail that arrives during the hidden pass as read, under the
    /// cover.
    func testBottomAnchorVisibleForFollowing_transcriptNotRevealed_isFalse() {
        XCTAssertFalse(isBottomAnchorVisibleForFollowing(isReadyToShow: false))
    }

    /// Revert-check: dropping `initialLoadPhase == .loaded` from
    /// `ChatTranscriptPresentationPolicy.isBottomAnchorVisibleForFollowing`
    /// reads a revealed transcript with no rows as resting at its bottom.
    func testBottomAnchorVisibleForFollowing_windowNotLoaded_isFalse() {
        for phase in [Phase.loading, .empty, .failed] {
            XCTAssertFalse(isBottomAnchorVisibleForFollowing(phase: phase), "phase=\(phase)")
        }
    }

    /// Revert-check: dropping `!isUserScrollGestureActive` from
    /// `ChatTranscriptPresentationPolicy.isBottomAnchorVisibleForFollowing`
    /// scrolls a reader whose finger is on the transcript when a message
    /// arrives.
    func testBottomAnchorVisibleForFollowing_fingerOnTranscript_isFalse() {
        XCTAssertFalse(isBottomAnchorVisibleForFollowing(isUserScrollGestureActive: true))
    }

    /// Revert-check: dropping `!isUserScrollTakeoverActive` from
    /// `ChatTranscriptPresentationPolicy.isBottomAnchorVisibleForFollowing`
    /// pulls a reader who scrolled away back to the bottom as the anchor
    /// passes through the viewport.
    func testBottomAnchorVisibleForFollowing_userScrollTakeover_isFalse() {
        XCTAssertFalse(isBottomAnchorVisibleForFollowing(isUserScrollTakeoverActive: true))
    }

    /// Revert-check: dropping `isBottomAnchorInViewport` from
    /// `ChatTranscriptPresentationPolicy.isBottomAnchorVisibleForFollowing`
    /// treats a reader in the history as at the bottom.
    func testBottomAnchorVisibleForFollowing_anchorOutsideViewport_isFalse() {
        XCTAssertFalse(isBottomAnchorVisibleForFollowing(isBottomAnchorInViewport: false))
    }

    // MARK: - Initial-anchor hold

    /// Revert-check: returning nil for a reveal from the `.revealChanged`
    /// case of `ChatTranscriptPresentationPolicy.initialAnchorHoldChange`
    /// leaves the hold armed after the reveal, so no row `onAppear` moves
    /// the virtual window again.
    func testInitialAnchorHoldChange_revealed_endsHold() {
        for isRestartable in [false, true] {
            XCTAssertEqual(
                Policy.initialAnchorHoldChange(
                    on: .revealChanged,
                    isReadyToShow: true,
                    isRevealRestartableFromEmpty: isRestartable
                ),
                .end,
                "restartable=\(isRestartable)"
            )
        }
    }

    /// The empty-to-loaded restart re-hides the transcript.
    ///
    /// Revert-check: returning nil for `isReadyToShow == false` from the
    /// `.revealChanged` case of
    /// `ChatTranscriptPresentationPolicy.initialAnchorHoldChange` runs the
    /// restarted hidden pass without the hold the first-open pass has.
    func testInitialAnchorHoldChange_rehidden_armsHold() {
        XCTAssertEqual(
            Policy.initialAnchorHoldChange(
                on: .revealChanged,
                isReadyToShow: false,
                isRevealRestartableFromEmpty: false
            ),
            .begin
        )
    }

    /// Revert-check: returning nil from the `.appeared` case of
    /// `ChatTranscriptPresentationPolicy.initialAnchorHoldChange` keeps the
    /// hold on a transcript that re-appears already revealed, which
    /// publishes no `isReadyToShow` change to release it.
    func testInitialAnchorHoldChange_appearedAlreadyRevealed_endsHold() {
        XCTAssertEqual(
            Policy.initialAnchorHoldChange(
                on: .appeared,
                isReadyToShow: true,
                isRevealRestartableFromEmpty: false
            ),
            .end
        )
    }

    /// Revert-check: returning `.end` unconditionally from the `.appeared`
    /// or `.initialWindowPublished` case of
    /// `ChatTranscriptPresentationPolicy.initialAnchorHoldChange` releases
    /// the hold in the middle of the hidden pass it protects.
    func testInitialAnchorHoldChange_passStillHidden_leavesHoldAlone() {
        for event in [Policy.InitialAnchorHoldEvent.appeared, .initialWindowPublished] {
            XCTAssertNil(
                Policy.initialAnchorHoldChange(
                    on: event,
                    isReadyToShow: false,
                    isRevealRestartableFromEmpty: false
                ),
                "event=\(event)"
            )
        }
    }

    /// Revert-check: returning nil from the `.initialWindowPublished` case
    /// of `ChatTranscriptPresentationPolicy.initialAnchorHoldChange` leaves
    /// the hold a re-publish armed after a terminal reveal, which no
    /// `isReadyToShow` change will ever release.
    func testInitialAnchorHoldChange_windowRepublishedAfterTerminalReveal_endsHold() {
        XCTAssertEqual(
            Policy.initialAnchorHoldChange(
                on: .initialWindowPublished,
                isReadyToShow: true,
                isRevealRestartableFromEmpty: false
            ),
            .end
        )
    }

    /// Revert-check: dropping `!isRevealRestartableFromEmpty` from the
    /// `.initialWindowPublished` case of
    /// `ChatTranscriptPresentationPolicy.initialAnchorHoldChange` releases
    /// the hold the restarted pass needs when messages arrive in an empty
    /// conversation.
    func testInitialAnchorHoldChange_windowRepublishedOverEmptyReveal_keepsHoldForRestart() {
        XCTAssertNil(
            Policy.initialAnchorHoldChange(
                on: .initialWindowPublished,
                isReadyToShow: true,
                isRevealRestartableFromEmpty: true
            )
        )
    }
}
