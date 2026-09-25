import XCTest
@testable import esc_chatmail

/// Pins the decisions behind "replies show up under the keyboard": inset
/// growth (keyboard show, "Replying to" row, wrapped draft lines, attachment
/// strip) shifts the transcript by the growth so the content above the
/// composer stays visible, a keyboard hide returns the shift its show made,
/// and the spacer takes growth without animation so the shift lands exactly.
///
/// Geometry below uses the iPhone 17 Pro values the simulator measured: a
/// 724pt scroll frame, a 50.7pt reply bar, and a 335pt keyboard (301pt above
/// the 34pt home-indicator inset) animating for 0.383s.
///
/// HONEST SCOPE: these tests cover the policy only. The view wiring
/// (`ChatMessagesView.handleBottomInsetChange`) and the scroll itself
/// (`ChatTranscriptOffsetShifter`) have no unit seam, because there is no UI
/// test target. They were exercised in the real `ChatView` on the iOS 26.5
/// simulator with XCUITest-driven drags, taps and typing against a seeded
/// conversation (a temporary harness, not checked in).
final class ChatBottomInsetPolicyTests: XCTestCase {
    private typealias Components = ChatBottomInsetPolicy.Components

    private let viewportHeight: CGFloat = 724
    private let replyBarHeight: CGFloat = 50.7
    private let keyboardOffset: CGFloat = 301
    private let keyboardDuration: TimeInterval = 0.383
    /// A reader scrolled a little above the bottom, as in the report.
    private let scrolledUpOffsetY: CGFloat = 2000
    private var scrolledUpAnchorMaxY: CGFloat { viewportHeight + 120 }

    private var keyboardHidden: Components {
        Components(replyBarHeight: replyBarHeight, keyboardOffset: 0)
    }

    private var keyboardShown: Components {
        Components(replyBarHeight: replyBarHeight, keyboardOffset: keyboardOffset)
    }

    private var withReplyingToRow: Components {
        Components(replyBarHeight: replyBarHeight + 30, keyboardOffset: keyboardOffset)
    }

    private func inputs(
        from oldComponents: Components,
        to newComponents: Components,
        observedOffsetY: CGFloat? = nil,
        bottomAnchorMaxY: CGFloat? = nil,
        isOffsetShiftAvailable: Bool = true,
        compensatesGrowth: Bool = true,
        defersGrowth: Bool = false,
        isInteractiveDismissal: Bool = false,
        now: TimeInterval = 100
    ) -> ChatBottomInsetPolicy.ShiftInputs {
        ChatBottomInsetPolicy.ShiftInputs(
            oldComponents: oldComponents,
            newComponents: newComponents,
            observedOffsetY: observedOffsetY ?? scrolledUpOffsetY,
            bottomAnchorMaxY: bottomAnchorMaxY ?? scrolledUpAnchorMaxY,
            viewportHeight: viewportHeight,
            isOffsetShiftAvailable: isOffsetShiftAvailable,
            compensatesGrowth: compensatesGrowth,
            defersGrowth: defersGrowth,
            isInteractiveDismissal: isInteractiveDismissal,
            keyboardAnimationDuration: keyboardDuration,
            now: now
        )
    }

    // MARK: - Inset

    func testInset_emptyComponents_keepsOnePointSpacer() {
        XCTAssertEqual(Components(replyBarHeight: 0, keyboardOffset: 0).inset, 1)
    }

    func testInset_keyboardShown_sumsReplyBarAndKeyboard() {
        XCTAssertEqual(keyboardShown.inset, replyBarHeight + keyboardOffset, accuracy: 0.001)
    }

    // MARK: - Spacer transition

    /// Revert-check: returning `.inherited` for growth from
    /// `ChatBottomInsetPolicy.spacerTransition` animates the spacer again,
    /// which clamps the compensating shift to the mid-animation content size.
    func testSpacerTransition_keyboardShow_appliesImmediately() {
        XCTAssertEqual(
            ChatBottomInsetPolicy.spacerTransition(from: keyboardHidden, to: keyboardShown),
            .immediate
        )
    }

    func testSpacerTransition_replyBarGrowth_appliesImmediately() {
        XCTAssertEqual(
            ChatBottomInsetPolicy.spacerTransition(from: keyboardShown, to: withReplyingToRow),
            .immediate
        )
    }

    /// Revert-check: dropping the `.keyboardAnimation` branch from
    /// `ChatBottomInsetPolicy.spacerTransition` makes a keyboard hide inherit
    /// the transaction, so the spacer would no longer be guaranteed to
    /// shrink in step with the composer.
    func testSpacerTransition_keyboardHide_replaysKeyboardAnimation() {
        XCTAssertEqual(
            ChatBottomInsetPolicy.spacerTransition(from: keyboardShown, to: keyboardHidden),
            .keyboardAnimation
        )
    }

    func testSpacerTransition_keyboardHideWhileReplyBarGrows_replaysKeyboardAnimation() {
        let hiddenWithTallerBar = Components(replyBarHeight: replyBarHeight + 30, keyboardOffset: 0)

        XCTAssertEqual(
            ChatBottomInsetPolicy.spacerTransition(from: keyboardShown, to: hiddenWithTallerBar),
            .keyboardAnimation
        )
    }

    func testSpacerTransition_replyBarShrink_inheritsTransaction() {
        XCTAssertEqual(
            ChatBottomInsetPolicy.spacerTransition(from: withReplyingToRow, to: keyboardShown),
            .inherited
        )
    }

    func testSpacerTransition_subPointJitter_inheritsTransaction() {
        let jittered = Components(replyBarHeight: replyBarHeight + 0.3, keyboardOffset: keyboardOffset)

        XCTAssertEqual(
            ChatBottomInsetPolicy.spacerTransition(from: keyboardShown, to: jittered),
            .inherited
        )
    }

    // MARK: - Gates

    func testIsOffsetShiftAvailable_supportedAndRevealed_isAvailable() {
        XCTAssertTrue(
            ChatBottomInsetPolicy.isOffsetShiftAvailable(supportsOffsetShift: true, isTranscriptRevealed: true)
        )
    }

    /// Before iOS 26 the coordinator's scroll-to-bottom stays in charge.
    func testIsOffsetShiftAvailable_withoutOffsetShiftSupport_isUnavailable() {
        XCTAssertFalse(
            ChatBottomInsetPolicy.isOffsetShiftAvailable(supportsOffsetShift: false, isTranscriptRevealed: true)
        )
    }

    /// The hidden initial anchor pass owns scrolling until the reveal.
    func testIsOffsetShiftAvailable_beforeReveal_isUnavailable() {
        XCTAssertFalse(
            ChatBottomInsetPolicy.isOffsetShiftAvailable(supportsOffsetShift: true, isTranscriptRevealed: false)
        )
    }

    func testCompensatesGrowth_availableUncoveredIdleTranscript_compensates() {
        XCTAssertTrue(
            ChatBottomInsetPolicy.compensatesGrowth(
                isOffsetShiftAvailable: true,
                isChatActiveAndUncovered: true,
                isComposerFocused: false,
                isUserScrollGestureActive: false
            )
        )
    }

    /// `KeyboardResponder` is app-global: a keyboard raised in a sheet over
    /// the chat also grows the hidden transcript's inset.
    ///
    /// Revert-check: dropping the coverage gate from
    /// `ChatBottomInsetPolicy.compensatesGrowth` shifts the covered
    /// transcript by the sheet keyboard's height.
    func testCompensatesGrowth_sheetKeyboardOverCoveredChat_doesNotCompensate() {
        XCTAssertFalse(
            ChatBottomInsetPolicy.compensatesGrowth(
                isOffsetShiftAvailable: true,
                isChatActiveAndUncovered: false,
                isComposerFocused: false,
                isUserScrollGestureActive: false
            )
        )
    }

    /// UIKit restores the reply field's keyboard while a sheet is still
    /// dismissing (and on return to the foreground); its hide was returned,
    /// so the show must shift to stay symmetric.
    ///
    /// Revert-check: dropping `isComposerFocused` from
    /// `ChatBottomInsetPolicy.compensatesGrowth` leaves this show uncompensated.
    func testCompensatesGrowth_composerKeyboardRestoredWhileStillCovered_compensates() {
        XCTAssertTrue(
            ChatBottomInsetPolicy.compensatesGrowth(
                isOffsetShiftAvailable: true,
                isChatActiveAndUncovered: false,
                isComposerFocused: true,
                isUserScrollGestureActive: false
            )
        )
    }

    func testCompensatesGrowth_duringUserDrag_doesNotCompensate() {
        XCTAssertFalse(
            ChatBottomInsetPolicy.compensatesGrowth(
                isOffsetShiftAvailable: true,
                isChatActiveAndUncovered: true,
                isComposerFocused: true,
                isUserScrollGestureActive: true
            )
        )
    }

    func testCompensatesGrowth_shiftUnavailable_doesNotCompensate() {
        XCTAssertFalse(
            ChatBottomInsetPolicy.compensatesGrowth(
                isOffsetShiftAvailable: false,
                isChatActiveAndUncovered: true,
                isComposerFocused: true,
                isUserScrollGestureActive: false
            )
        )
    }

    func testDefersGrowth_keyboardOfSheetCoveringChat_isDeferred() {
        XCTAssertTrue(
            ChatBottomInsetPolicy.defersGrowth(
                isOffsetShiftAvailable: true,
                isChatActiveAndUncovered: false,
                isComposerFocused: false
            )
        )
    }

    func testDefersGrowth_uncoveredOrComposerFocusedOrUnavailable_isNotDeferred() {
        XCTAssertFalse(
            ChatBottomInsetPolicy.defersGrowth(
                isOffsetShiftAvailable: true,
                isChatActiveAndUncovered: true,
                isComposerFocused: false
            )
        )
        XCTAssertFalse(
            ChatBottomInsetPolicy.defersGrowth(
                isOffsetShiftAvailable: true,
                isChatActiveAndUncovered: false,
                isComposerFocused: true
            )
        )
        XCTAssertFalse(
            ChatBottomInsetPolicy.defersGrowth(
                isOffsetShiftAvailable: false,
                isChatActiveAndUncovered: false,
                isComposerFocused: false
            )
        )
    }

    func testIsInteractiveDismissal_scrollViewStillInteracting_isInteractive() {
        XCTAssertTrue(
            ChatBottomInsetPolicy.isInteractiveDismissal(
                isUserScrollInteractionActive: true,
                lastUserScrollInteractionEndedAt: nil,
                now: 100
            )
        )
    }

    /// keyboardWillHide arrived ~8ms after the dismissing drag ended.
    func testIsInteractiveDismissal_hideJustAfterInteractionEnded_isInteractive() {
        XCTAssertTrue(
            ChatBottomInsetPolicy.isInteractiveDismissal(
                isUserScrollInteractionActive: false,
                lastUserScrollInteractionEndedAt: 100 - 0.008,
                now: 100
            )
        )
    }

    /// A tap-to-dismiss never pans the scroll view (even when the finger
    /// travels a few points), so only an old interaction can precede it.
    func testIsInteractiveDismissal_hideLongAfterLastInteraction_isNotInteractive() {
        XCTAssertFalse(
            ChatBottomInsetPolicy.isInteractiveDismissal(
                isUserScrollInteractionActive: false,
                lastUserScrollInteractionEndedAt: 99,
                now: 100
            )
        )
        XCTAssertFalse(
            ChatBottomInsetPolicy.isInteractiveDismissal(
                isUserScrollInteractionActive: false,
                lastUserScrollInteractionEndedAt: nil,
                now: 100
            )
        )
    }

    // MARK: - Scroll range

    func testMaximumOffsetY_atExactBottom_growsByInsetChange() {
        XCTAssertEqual(
            ChatBottomInsetPolicy.maximumOffsetY(
                observedOffsetY: 2000,
                bottomAnchorMaxY: viewportHeight,
                viewportHeight: viewportHeight,
                insetChange: keyboardOffset
            ),
            2000 + keyboardOffset
        )
    }

    /// A short thread is floored to the viewport height, so its range never
    /// goes below the content top.
    func testMaximumOffsetY_shortTranscriptThatStillFits_isZero() {
        XCTAssertEqual(
            ChatBottomInsetPolicy.maximumOffsetY(
                observedOffsetY: 0,
                bottomAnchorMaxY: 300,
                viewportHeight: viewportHeight,
                insetChange: keyboardOffset
            ),
            0
        )
    }

    /// Far up in history the lazy stack has not realized the bottom anchor;
    /// the content then extends well below the viewport, so nothing clamps.
    func testMaximumOffsetY_unrealizedBottomAnchor_isUnbounded() {
        XCTAssertNil(
            ChatBottomInsetPolicy.maximumOffsetY(
                observedOffsetY: 2000,
                bottomAnchorMaxY: nil,
                viewportHeight: viewportHeight,
                insetChange: keyboardOffset
            )
        )
    }

    // MARK: - Shift planning: growth

    /// The reported bug: a reader scrolled a little above the bottom taps the
    /// field, and the keyboard covered the bottom of what they were reading.
    /// Now the content above the composer moves up with it, on the keyboard's
    /// own animation.
    ///
    /// Revert-check: returning nil from the growth branch of
    /// `ChatBottomInsetPolicy.shift` (no compensation, the previous
    /// behaviour) fails this test.
    func testShift_keyboardShowWhileScrolledUp_scrollsUpByKeyboardHeightOnKeyboardAnimation() {
        var state = ChatBottomInsetPolicy.ShiftState()

        let shift = ChatBottomInsetPolicy.shift(
            for: inputs(from: keyboardHidden, to: keyboardShown),
            state: &state
        )

        XCTAssertEqual(
            shift,
            .init(
                targetY: scrolledUpOffsetY + keyboardOffset,
                animationDuration: keyboardDuration,
                direction: .towardNewer
            )
        )
        XCTAssertEqual(state.outstandingKeyboardShift, keyboardOffset, accuracy: 0.001)
    }

    func testShift_keyboardShowAtExactBottom_landsOnNewBottom() {
        var state = ChatBottomInsetPolicy.ShiftState()

        let shift = ChatBottomInsetPolicy.shift(
            for: inputs(from: keyboardHidden, to: keyboardShown, bottomAnchorMaxY: viewportHeight),
            state: &state
        )

        XCTAssertEqual(shift?.targetY, scrolledUpOffsetY + keyboardOffset)
    }

    func testShift_keyboardShowFarUpWithUnrealizedAnchor_scrollsByKeyboardHeight() {
        var state = ChatBottomInsetPolicy.ShiftState()
        var farUp = inputs(from: keyboardHidden, to: keyboardShown)
        farUp.bottomAnchorMaxY = nil

        let shift = ChatBottomInsetPolicy.shift(for: farUp, state: &state)

        XCTAssertEqual(shift?.targetY, scrolledUpOffsetY + keyboardOffset)
    }

    /// Context-menu Reply shows the "Replying to" row, and wrapped draft
    /// lines grow the composer, each in one frame; they used to cover the
    /// last message with no scroll response, and an eased shift left the
    /// newest content under the grown composer for up to 0.2s per line.
    ///
    /// Revert-check: giving reply-bar growth an animation duration in
    /// `ChatBottomInsetPolicy.shift` fails this test.
    func testShift_replyingToRowAppears_jumpsByRowHeightWithoutAnimation() {
        var state = ChatBottomInsetPolicy.ShiftState()

        let shift = ChatBottomInsetPolicy.shift(
            for: inputs(from: keyboardShown, to: withReplyingToRow),
            state: &state
        )

        XCTAssertEqual(
            shift,
            .init(targetY: scrolledUpOffsetY + 30, animationDuration: nil, direction: .towardNewer)
        )
        XCTAssertEqual(state.outstandingKeyboardShift, 0)
    }

    /// A short thread's grown content may still fit; shifting would park the
    /// scroll view past its end.
    ///
    /// Revert-check: removing the `maximumOffsetY` clamp from the growth
    /// branch of `ChatBottomInsetPolicy.shift` plans a 301pt shift here.
    func testShift_shortTranscriptThatStillFits_doesNotScroll() {
        var state = ChatBottomInsetPolicy.ShiftState()

        let shift = ChatBottomInsetPolicy.shift(
            for: inputs(from: keyboardHidden, to: keyboardShown, observedOffsetY: 0, bottomAnchorMaxY: 300),
            state: &state
        )

        XCTAssertNil(shift)
        XCTAssertEqual(state.outstandingKeyboardShift, 0)
    }

    /// Only the clamped amount is recorded for the hide to return.
    ///
    /// Revert-check: accruing the full keyboard growth instead of
    /// `min(amount, keyboardGrowth + owed)` in `ChatBottomInsetPolicy.shift`
    /// records 301 here.
    func testShift_shortTranscriptThatOverflows_scrollsAndRecordsOnlyTheOverflow() {
        var state = ChatBottomInsetPolicy.ShiftState()

        let shift = ChatBottomInsetPolicy.shift(
            for: inputs(from: keyboardHidden, to: keyboardShown, observedOffsetY: 0, bottomAnchorMaxY: 600),
            state: &state
        )

        let overflow = 600 + keyboardOffset - viewportHeight
        XCTAssertEqual(shift?.targetY ?? -1, overflow, accuracy: 0.001)
        XCTAssertEqual(state.outstandingKeyboardShift, overflow, accuracy: 0.001)
    }

    /// A keyboard that publishes its height in two steps (or a composer that
    /// grows while the keyboard is still rising) must add up; basing the
    /// second shift on the mid-animation offset lost the rest of the first.
    ///
    /// Revert-check: making `shiftBase` in `ChatBottomInsetPolicy` always
    /// return the observed offset lands the second target at
    /// 2100 + 44 instead of 2000 + 301 + 44.
    func testShift_secondGrowthDuringInFlightShift_buildsOnPendingTarget() throws {
        var state = ChatBottomInsetPolicy.ShiftState()
        let first = try XCTUnwrap(
            ChatBottomInsetPolicy.shift(for: inputs(from: keyboardHidden, to: keyboardShown, now: 100), state: &state)
        )
        let tallerKeyboard = Components(replyBarHeight: replyBarHeight, keyboardOffset: keyboardOffset + 44)

        let second = ChatBottomInsetPolicy.shift(
            for: inputs(
                from: keyboardShown,
                to: tallerKeyboard,
                observedOffsetY: scrolledUpOffsetY + 100,
                bottomAnchorMaxY: scrolledUpAnchorMaxY + keyboardOffset - 100,
                now: 100.1
            ),
            state: &state
        )

        XCTAssertEqual(second?.targetY, first.targetY + 44)
        XCTAssertEqual(state.outstandingKeyboardShift, keyboardOffset + 44, accuracy: 0.001)
    }

    func testShift_growthAfterEarlierShiftSettled_buildsOnObservedOffset() throws {
        var state = ChatBottomInsetPolicy.ShiftState()
        _ = try XCTUnwrap(
            ChatBottomInsetPolicy.shift(for: inputs(from: keyboardHidden, to: keyboardShown, now: 100), state: &state)
        )

        let second = ChatBottomInsetPolicy.shift(
            for: inputs(from: keyboardShown, to: withReplyingToRow, observedOffsetY: 2250, now: 102),
            state: &state
        )

        XCTAssertEqual(second?.targetY, 2250 + 30)
    }

    func testShift_growthWhileNotCompensated_doesNotScrollOrRecordShift() {
        var state = ChatBottomInsetPolicy.ShiftState()

        XCTAssertNil(
            ChatBottomInsetPolicy.shift(
                for: inputs(from: keyboardHidden, to: keyboardShown, compensatesGrowth: false),
                state: &state
            )
        )
        XCTAssertEqual(state, ChatBottomInsetPolicy.ShiftState())
    }

    func testShift_replyBarShrink_doesNotScroll() {
        var state = ChatBottomInsetPolicy.ShiftState()

        XCTAssertNil(
            ChatBottomInsetPolicy.shift(
                for: inputs(from: withReplyingToRow, to: keyboardShown),
                state: &state
            )
        )
    }

    func testShift_subPointJitter_doesNotScroll() {
        var state = ChatBottomInsetPolicy.ShiftState()
        let jittered = Components(replyBarHeight: replyBarHeight + 0.3, keyboardOffset: keyboardOffset)

        XCTAssertNil(
            ChatBottomInsetPolicy.shift(for: inputs(from: keyboardShown, to: jittered), state: &state)
        )
    }

    // MARK: - Shift planning: keyboard hide

    /// Focus then tap-to-dismiss leaves the reader where they were; a
    /// growth-only compensation drifted them ~300pt toward newer content on
    /// every cycle.
    ///
    /// Revert-check: deleting the keyboard-shrink return in
    /// `ChatBottomInsetPolicy.shift` leaves the hide unplanned.
    func testShift_keyboardShowThenTapDismiss_returnsToOriginalOffset() throws {
        var state = ChatBottomInsetPolicy.ShiftState()
        let show = try XCTUnwrap(
            ChatBottomInsetPolicy.shift(for: inputs(from: keyboardHidden, to: keyboardShown, now: 100), state: &state)
        )

        let hide = ChatBottomInsetPolicy.shift(
            for: inputs(
                from: keyboardShown,
                to: keyboardHidden,
                observedOffsetY: show.targetY,
                now: 105
            ),
            state: &state
        )

        XCTAssertEqual(
            hide,
            .init(targetY: scrolledUpOffsetY, animationDuration: keyboardDuration, direction: .towardOlder)
        )
        XCTAssertEqual(state.outstandingKeyboardShift, 0)
    }

    /// The finger already moved the content during an interactive dismissal;
    /// returning the show's shift lurched it a second time after release.
    ///
    /// Revert-check: removing the `isInteractiveDismissal` branch from
    /// `ChatBottomInsetPolicy.shift` plans a return here.
    func testShift_interactiveDismissal_doesNotReturnAndForgetsShowShift() throws {
        var state = ChatBottomInsetPolicy.ShiftState()
        _ = try XCTUnwrap(
            ChatBottomInsetPolicy.shift(for: inputs(from: keyboardHidden, to: keyboardShown, now: 100), state: &state)
        )

        let hide = ChatBottomInsetPolicy.shift(
            for: inputs(
                from: keyboardShown,
                to: keyboardHidden,
                observedOffsetY: 1900,
                isInteractiveDismissal: true,
                now: 105
            ),
            state: &state
        )

        XCTAssertNil(hide)
        XCTAssertEqual(state, ChatBottomInsetPolicy.ShiftState())
    }

    /// A sheet's own keyboard never shifted the transcript, so its hide has
    /// nothing to return.
    func testShift_keyboardHideWithoutCompensatedShow_doesNotScroll() {
        var state = ChatBottomInsetPolicy.ShiftState()
        XCTAssertNil(
            ChatBottomInsetPolicy.shift(
                for: inputs(from: keyboardHidden, to: keyboardShown, compensatesGrowth: false),
                state: &state
            )
        )

        let hide = ChatBottomInsetPolicy.shift(
            for: inputs(from: keyboardShown, to: keyboardHidden),
            state: &state
        )

        XCTAssertNil(hide)
        XCTAssertEqual(state.outstandingKeyboardShift, 0)
    }

    /// A short thread whose clamped show shift was followed by a sent reply:
    /// post-send anchoring moved to the new bottom, and once the keyboard's
    /// spacer shrinks the thread fits again. Returning the full recorded
    /// shift would park the scroll view 70pt past its end.
    ///
    /// Revert-check: removing the `maximumOffsetY` clamp from the return in
    /// `ChatBottomInsetPolicy.shift` plans a target of 70 here.
    func testShift_returnAfterContentFitsAgain_clampsToScrollRange() throws {
        var state = ChatBottomInsetPolicy.ShiftState()
        let show = try XCTUnwrap(
            ChatBottomInsetPolicy.shift(
                for: inputs(from: keyboardHidden, to: keyboardShown, observedOffsetY: 0, bottomAnchorMaxY: 600, now: 100),
                state: &state
            )
        )
        XCTAssertEqual(show.targetY, 177, accuracy: 0.001)
        let afterSentReplyAtBottom: CGFloat = 247

        let hide = ChatBottomInsetPolicy.shift(
            for: inputs(
                from: keyboardShown,
                to: keyboardHidden,
                observedOffsetY: afterSentReplyAtBottom,
                bottomAnchorMaxY: viewportHeight,
                now: 105
            ),
            state: &state
        )

        XCTAssertEqual(hide?.targetY, 0)
    }

    func testShift_returnLargerThanCurrentOffset_clampsToContentTop() throws {
        var state = ChatBottomInsetPolicy.ShiftState()
        _ = try XCTUnwrap(
            ChatBottomInsetPolicy.shift(for: inputs(from: keyboardHidden, to: keyboardShown, now: 100), state: &state)
        )

        let hide = ChatBottomInsetPolicy.shift(
            for: inputs(from: keyboardShown, to: keyboardHidden, observedOffsetY: 120, now: 105),
            state: &state
        )

        XCTAssertEqual(hide?.targetY, 0)
    }

    func testShift_shiftUnavailable_doesNotScrollAndDropsPendingReturn() throws {
        var state = ChatBottomInsetPolicy.ShiftState()
        _ = try XCTUnwrap(
            ChatBottomInsetPolicy.shift(for: inputs(from: keyboardHidden, to: keyboardShown), state: &state)
        )

        let hide = ChatBottomInsetPolicy.shift(
            for: inputs(from: keyboardShown, to: keyboardHidden, isOffsetShiftAvailable: false),
            state: &state
        )

        XCTAssertNil(hide)
        XCTAssertEqual(state, ChatBottomInsetPolicy.ShiftState())
    }

    func testShiftSettleDuration_addsOneTenthSecondToAnimation() {
        let animated = ChatBottomInsetPolicy.Shift(targetY: 0, animationDuration: 0.383, direction: .towardNewer)
        let jump = ChatBottomInsetPolicy.Shift(targetY: 0, animationDuration: nil, direction: .towardNewer)

        XCTAssertEqual(animated.settleDuration, 0.483, accuracy: 0.0001)
        XCTAssertEqual(jump.settleDuration, 0.1, accuracy: 0.0001)
    }

    // MARK: - Shift planning: keyboard hand-off and in-flight shifts

    /// A sheet's own keyboard was handed back to the composer without a hide
    /// (the sheet dismissed while its field was focused). Only the 27pt
    /// keyboard-type difference changed the inset, and shifting just that
    /// left the newest messages ~274pt under the composer's keyboard.
    ///
    /// Revert-check: dropping `owed` from `wanted` in
    /// `ChatBottomInsetPolicy.shift` shifts only 27pt here.
    func testShift_sheetKeyboardHandedBackWithoutHide_makesUpOwedGrowth() {
        var state = ChatBottomInsetPolicy.ShiftState()
        let sheetKeyboard = Components(replyBarHeight: replyBarHeight, keyboardOffset: 274)
        XCTAssertNil(
            ChatBottomInsetPolicy.shift(
                for: inputs(
                    from: keyboardHidden,
                    to: sheetKeyboard,
                    compensatesGrowth: false,
                    defersGrowth: true,
                    now: 100
                ),
                state: &state
            )
        )
        XCTAssertEqual(state.owedKeyboardShift, 274, accuracy: 0.001)

        // The uncompensated sheet keyboard already pushed the anchor 274pt down.
        let handBack = ChatBottomInsetPolicy.shift(
            for: inputs(
                from: sheetKeyboard,
                to: keyboardShown,
                bottomAnchorMaxY: scrolledUpAnchorMaxY + 274,
                now: 102
            ),
            state: &state
        )

        XCTAssertEqual(
            handBack,
            .init(
                targetY: scrolledUpOffsetY + keyboardOffset,
                animationDuration: keyboardDuration,
                direction: .towardNewer
            )
        )
        XCTAssertEqual(state.owedKeyboardShift, 0)
        XCTAssertEqual(state.outstandingKeyboardShift, keyboardOffset, accuracy: 0.001)
    }

    /// The hand-off can also leave the inset unchanged; the view then calls
    /// the policy with identical components when compensation resumes (that
    /// call itself, `onChange(of: compensatesBottomInsetGrowth)`, is covered
    /// only by the simulator runs).
    ///
    /// Revert-check: dropping `owed` from `wanted` in
    /// `ChatBottomInsetPolicy.shift` plans nothing here.
    func testShift_compensationResumesWithUnchangedInset_makesUpOwedGrowth() {
        var state = ChatBottomInsetPolicy.ShiftState()
        state.owedKeyboardShift = keyboardOffset

        let shift = ChatBottomInsetPolicy.shift(
            for: inputs(
                from: keyboardShown,
                to: keyboardShown,
                bottomAnchorMaxY: scrolledUpAnchorMaxY + keyboardOffset
            ),
            state: &state
        )

        XCTAssertEqual(shift?.targetY, scrolledUpOffsetY + keyboardOffset)
        XCTAssertEqual(state.owedKeyboardShift, 0)
    }

    /// A sheet's keyboard that hides normally takes its owed growth with it;
    /// it must not return a shift the composer's keyboard made.
    ///
    /// Revert-check: removing the owed pay-down from
    /// `ChatBottomInsetPolicy.keyboardReturn` plans a return to 1846 here (100pt
    /// debited from the outstanding shift, then clamped to the shrunken range).
    func testShift_owedKeyboardHides_paysOwedBeforeReturningComposerShift() {
        var state = ChatBottomInsetPolicy.ShiftState()
        state.outstandingKeyboardShift = 100
        state.owedKeyboardShift = 274
        let sheetKeyboard = Components(replyBarHeight: replyBarHeight, keyboardOffset: 274)

        let hide = ChatBottomInsetPolicy.shift(
            for: inputs(from: sheetKeyboard, to: keyboardHidden),
            state: &state
        )

        XCTAssertNil(hide)
        XCTAssertEqual(state.owedKeyboardShift, 0)
        XCTAssertEqual(state.outstandingKeyboardShift, 100)
    }

    /// Growth skipped during a drag is not owed: making it up after the drag
    /// would move content the reader just placed.
    func testShift_keyboardGrowthDuringDrag_isNotOwed() {
        var state = ChatBottomInsetPolicy.ShiftState()

        XCTAssertNil(
            ChatBottomInsetPolicy.shift(
                for: inputs(from: keyboardHidden, to: keyboardShown, compensatesGrowth: false, defersGrowth: false),
                state: &state
            )
        )
        XCTAssertEqual(state.owedKeyboardShift, 0)
    }

    /// At the bottom, a second keyboard step arrives mid-shift while the
    /// anchor sample is a frame ahead of the offset sample. Re-clamping the
    /// in-flight target against that mixed pair stopped the shift ~20pt short.
    ///
    /// Revert-check: clamping the pending base in `ChatBottomInsetPolicy.shift`
    /// (ignoring `isPendingTarget`) lands at 2325 instead of 2345.
    func testShift_secondGrowthMidShiftFromBottom_doesNotReclampPendingTarget() throws {
        var state = ChatBottomInsetPolicy.ShiftState()
        let first = try XCTUnwrap(
            ChatBottomInsetPolicy.shift(
                for: inputs(from: keyboardHidden, to: keyboardShown, bottomAnchorMaxY: viewportHeight, now: 100),
                state: &state
            )
        )
        XCTAssertEqual(first.targetY, scrolledUpOffsetY + keyboardOffset)
        let tallerKeyboard = Components(replyBarHeight: replyBarHeight, keyboardOffset: keyboardOffset + 44)
        // Offset sampled 100pt into the shift; anchor sampled one 20pt frame later.
        let observedOffsetY = scrolledUpOffsetY + 100
        let anchorOneFrameAhead = viewportHeight + keyboardOffset - 100 - 20

        let second = ChatBottomInsetPolicy.shift(
            for: inputs(
                from: keyboardShown,
                to: tallerKeyboard,
                observedOffsetY: observedOffsetY,
                bottomAnchorMaxY: anchorOneFrameAhead,
                now: 100.1
            ),
            state: &state
        )

        XCTAssertEqual(second?.targetY, first.targetY + 44)
    }

    // MARK: - State transitions

    /// Revert-check: removing the `pendingTargetY` reset from
    /// `ChatBottomInsetPolicy.coordinatorDidScroll` bases the next shift on
    /// the dead target.
    func testCoordinatorDidScroll_clearsPendingTargetAndOwedGrowth() {
        var state = ChatBottomInsetPolicy.ShiftState(
            pendingTargetY: 2301,
            pendingSettlesAt: 200,
            outstandingKeyboardShift: 301,
            owedKeyboardShift: 274
        )

        ChatBottomInsetPolicy.coordinatorDidScroll(state: &state)

        XCTAssertNil(state.pendingTargetY)
        XCTAssertEqual(state.owedKeyboardShift, 0)
        XCTAssertEqual(state.outstandingKeyboardShift, 301)
    }

    /// Revert-check: emptying `ChatBottomInsetPolicy.userDidTakeOverScroll`
    /// leaves the dead target in place.
    func testUserDidTakeOverScroll_clearsOnlyPendingTarget() {
        var state = ChatBottomInsetPolicy.ShiftState(
            pendingTargetY: 2301,
            pendingSettlesAt: 200,
            outstandingKeyboardShift: 301,
            owedKeyboardShift: 274
        )

        ChatBottomInsetPolicy.userDidTakeOverScroll(state: &state)

        XCTAssertNil(state.pendingTargetY)
        XCTAssertEqual(state.owedKeyboardShift, 274)
        XCTAssertEqual(state.outstandingKeyboardShift, 301)
    }
}
