import CoreGraphics
import Foundation

/// Pure decisions for how the chat transcript reacts when its bottom inset
/// (reply composer + keyboard) changes, per the house convention that view
/// decisions live in `enum XPolicy` namespaces. `ChatMessagesView` executes
/// them; `ChatTranscriptOffsetShifter` performs the scroll.
///
/// Why this exists ("replies show up under the keyboard"): the inset is a
/// trailing spacer inside the lazy transcript, under a `.top` scroll anchor, so
/// growing it only adds space *below* the viewport. The content offset does not
/// move, while the composer rises with the keyboard (or grows by a "Replying
/// to" row, wrapped draft lines, or an attachment strip) and covers the bottom
/// `growth` points of whatever the reader was looking at. The coordinator's
/// keyboard-show scroll-to-bottom never covered that: it is deliberately
/// suppressed during a user-scroll takeover (never yank a reader out of
/// history, see `ChatMessagesCoordinator.handleKeyboardHeightChange`), and
/// takeover stays latched until the reader rests within 1pt of the exact
/// bottom, so almost any earlier scroll left the next reply covered. Reply-bar
/// growth had no scroll response at all.
///
/// The fix shifts the scroll offset by the growth: content that sat just above
/// the composer stays just above it, at the bottom and scrolled up alike,
/// without moving the reader to a different part of the thread. A keyboard
/// hide returns the shift its show made, so focusing and dismissing leaves the
/// reader where they were. Two shrinks are deliberately not compensated:
/// - The hide that ends an interactive dismissal. The finger already moved the
///   content, and a return shift there lurched it a second time.
/// - Reply-bar shrink (a sent draft collapsing, a cleared "Replying to" row).
///   At the bottom the scroll view clamps the content down with the spacer.
///   Scrolled up, the freed space reveals newer content, and post-send
///   anchoring owns the scroll after a send.
enum ChatBottomInsetPolicy {
    /// Inputs of the transcript's bottom inset. Tracked as components rather
    /// than a total so the policy can tell a keyboard-driven change from a
    /// reply-bar one.
    struct Components: Equatable {
        var replyBarHeight: CGFloat
        /// Keyboard height above the bottom safe area (0 while hidden).
        var keyboardOffset: CGFloat

        /// Height of the trailing transcript spacer. The 1pt floor predates
        /// the separate 1pt bottom-anchor view (the spacer used to carry the
        /// anchor id, and a zero-height anchor frame never reads as visible);
        /// it is kept so the spacer is never a zero-height view.
        var inset: CGFloat {
            max(1, replyBarHeight + keyboardOffset)
        }
    }

    /// How the trailing spacer should take a new inset value.
    enum SpacerTransition: Equatable {
        /// Apply without animation. Growth must land in one frame: a scroll
        /// issued while the spacer is still animating is clamped by
        /// UIScrollView to the mid-animation content size and never
        /// re-targeted (simulator probe: the keyboard-show scroll-to-bottom
        /// landed ~19pt short at the bottom, and offset shifts wobbled by
        /// ±20pt). Growth itself is invisible under the `.top` anchor, so
        /// dropping its animation costs nothing on screen.
        case immediate
        /// Replay the keyboard's own animation (the curve and duration
        /// `KeyboardResponder` publishes the composer's offset with), so the
        /// spacer, and at the bottom the content the scroll view clamps
        /// with it, shrinks in lockstep with the composer on keyboard hide.
        case keyboardAnimation
        /// Keep whatever transaction delivered the change (reply-bar shrink),
        /// as the spacer did when it was computed in `body`.
        case inherited
    }

    /// Scroll bookkeeping the view carries between inset changes.
    struct ShiftState: Equatable {
        /// Target of the latest shift and when it settles. A shift requested
        /// while an earlier one is still animating builds on this target, not
        /// on the mid-animation offset; otherwise the rest of the first shift
        /// was lost (a keyboard publishing its height in two steps left part
        /// of the reader's content covered). Cleared when the reader or the
        /// coordinator scrolls.
        var pendingTargetY: CGFloat?
        var pendingSettlesAt: TimeInterval = 0
        /// Keyboard-driven shift not yet returned by a keyboard hide.
        var outstandingKeyboardShift: CGFloat = 0
        /// Keyboard growth skipped while the chat was covered by something
        /// else's keyboard (a sheet's text field). If that keyboard is handed
        /// back to the composer without a hide (the sheet dismissed while its
        /// field was focused), the next compensated update makes it up;
        /// otherwise the transcript sat ~270pt short with the newest messages
        /// under the composer's keyboard. A keyboard hide pays it down first.
        var owedKeyboardShift: CGFloat = 0
    }

    /// One scroll for `ChatTranscriptOffsetShifter` to perform.
    struct Shift: Equatable {
        enum Direction: Equatable {
            /// Compensates inset growth. The coordinator holds its bottom
            /// follow until `settleDuration` has passed
            /// (`ChatMessagesCoordinator.handleCompensatedInsetGrowth`).
            case towardNewer
            /// Returns a keyboard's shift on hide.
            case towardOlder
        }

        /// Absolute content-coordinate offset (0 = content top) to scroll to.
        let targetY: CGFloat
        /// nil: jump without animation. Reply-bar growth lands in a single
        /// frame, and an eased shift left the newest content under the grown
        /// composer for up to 0.2s per wrapped line.
        let animationDuration: TimeInterval?
        let direction: Direction

        /// How long the scroll is in flight, including the frame or two
        /// before the scroll geometry reports an unanimated jump.
        var settleDuration: TimeInterval {
            (animationDuration ?? 0) + ChatBottomInsetPolicy.shiftSettleSlack
        }
    }

    struct ShiftInputs {
        var oldComponents: Components
        var newComponents: Components
        /// Current offset in content coordinates, as last reported.
        var observedOffsetY: CGFloat
        /// Bottom edge of the transcript's trailing 1pt anchor in scroll-frame
        /// coordinates, before this change; nil while the lazy stack has not
        /// realized it (the reader is far enough up that the content extends
        /// well below the viewport).
        var bottomAnchorMaxY: CGFloat?
        /// Scroll-frame height in the same coordinates.
        var viewportHeight: CGFloat?
        /// `isOffsetShiftAvailable`.
        var isOffsetShiftAvailable: Bool
        /// `compensatesGrowth` for this update.
        var compensatesGrowth: Bool
        /// `defersGrowth` for this update.
        var defersGrowth: Bool
        /// `isInteractiveDismissal` for this update.
        var isInteractiveDismissal: Bool
        var keyboardAnimationDuration: TimeInterval
        var now: TimeInterval
    }

    /// Changes smaller than this are layout rounding, not a real inset change.
    static let changeTolerance: CGFloat = 0.5

    /// After the reader's scroll interaction ends, a keyboard hide arriving
    /// within this window is that drag's interactive dismissal. The simulator
    /// delivered `keyboardWillHide` about 8ms after the drag ended.
    static let interactiveDismissalWindow: TimeInterval = 0.25

    /// Added to a shift's animation time: the frame or two before the scroll
    /// geometry reports an unanimated jump.
    static let shiftSettleSlack: TimeInterval = 0.1

    static func spacerTransition(
        from oldComponents: Components,
        to newComponents: Components
    ) -> SpacerTransition {
        let change = newComponents.inset - oldComponents.inset
        if change > changeTolerance {
            return .immediate
        }
        if newComponents.keyboardOffset < oldComponents.keyboardOffset - changeTolerance {
            return .keyboardAnimation
        }
        return .inherited
    }

    /// Whether the transcript can be scrolled by these shifts at all.
    ///
    /// - Parameters:
    ///   - supportsOffsetShift: `ChatTranscriptOffsetShifter.isSupported`.
    ///   - isTranscriptRevealed: the initial anchor pass owns scrolling while
    ///     the transcript is hidden; a shift would race it.
    static func isOffsetShiftAvailable(
        supportsOffsetShift: Bool,
        isTranscriptRevealed: Bool
    ) -> Bool {
        supportsOffsetShift && isTranscriptRevealed
    }

    /// Whether inset growth right now is compensated by shifting the
    /// transcript. The view also passes it to
    /// `ChatMessagesCoordinator.handleKeyboardHeightChange` in the same
    /// update. When it is true and the reader is at the bottom, the
    /// coordinator skips its keyboard-show scroll-to-bottom, because the shift
    /// already lands on the new bottom. Off the bottom without a takeover the
    /// coordinator still scrolls to the latest message.
    ///
    /// - Parameters:
    ///   - isChatActiveAndUncovered: `KeyboardResponder` is app-global, so a
    ///     keyboard raised by a sheet over the chat (forward, add contact)
    ///     also grows the hidden transcript's inset; shifting for it moved a
    ///     scrolled-up reader ~300pt every time they typed in a sheet.
    ///   - isComposerFocused: the chat's own reply field has focus, so the
    ///     keyboard is the composer's even while the chat still reads as
    ///     covered: UIKit restores the field's keyboard during a sheet's
    ///     dismissal (before the sheet's `onDismiss`) and on return to the
    ///     foreground (before the scene is active again). Its hide was
    ///     returned, so its show must be compensated to stay symmetric.
    ///   - isUserScrollGestureActive: a programmatic scroll mid-drag fights
    ///     the finger.
    static func compensatesGrowth(
        isOffsetShiftAvailable: Bool,
        isChatActiveAndUncovered: Bool,
        isComposerFocused: Bool,
        isUserScrollGestureActive: Bool
    ) -> Bool {
        isOffsetShiftAvailable &&
            (isChatActiveAndUncovered || isComposerFocused) &&
            !isUserScrollGestureActive
    }

    /// Whether uncompensated keyboard growth is owed to the transcript for
    /// later (`ShiftState.owedKeyboardShift`): the keyboard belongs to
    /// something covering the chat. Growth skipped during a drag is not owed;
    /// making it up after the drag would move content the reader just placed.
    static func defersGrowth(
        isOffsetShiftAvailable: Bool,
        isChatActiveAndUncovered: Bool,
        isComposerFocused: Bool
    ) -> Bool {
        isOffsetShiftAvailable && !isChatActiveAndUncovered && !isComposerFocused
    }

    /// Whether a keyboard hide ends an interactive dismissal.
    ///
    /// Keyed on the scroll view's own interaction phase, not the transcript's
    /// 2pt drag detector: a tap-to-dismiss whose finger travels a few points
    /// trips that detector (and still fires the tap), which made an ordinary
    /// dismissal read as interactive and dropped the return shift. A real
    /// interactive dismissal pans the scroll view.
    ///
    /// - Parameters:
    ///   - isUserScrollInteractionActive: the scroll view is tracking,
    ///     interacting or decelerating.
    ///   - lastUserScrollInteractionEndedAt: when it last left those phases.
    static func isInteractiveDismissal(
        isUserScrollInteractionActive: Bool,
        lastUserScrollInteractionEndedAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        if isUserScrollInteractionActive {
            return true
        }
        guard let lastUserScrollInteractionEndedAt else { return false }
        return now - lastUserScrollInteractionEndedAt < interactiveDismissalWindow
    }

    /// The largest content offset once the inset has changed by
    /// `insetChange`, or nil when the content extends too far below the
    /// viewport for it to matter (the bottom anchor is unrealized).
    ///
    /// The content's natural bottom is the bottom anchor. A transcript
    /// shorter than the viewport is floored to the viewport height
    /// (`frame(minHeight:)`), so the range never goes below 0. Scrolling past
    /// this leaves the scroll view parked beyond its end until the next touch.
    static func maximumOffsetY(
        observedOffsetY: CGFloat,
        bottomAnchorMaxY: CGFloat?,
        viewportHeight: CGFloat?,
        insetChange: CGFloat
    ) -> CGFloat? {
        guard let bottomAnchorMaxY, let viewportHeight else { return nil }
        return max(0, observedOffsetY + bottomAnchorMaxY + insetChange - viewportHeight)
    }

    /// The scroll (if any) that keeps the content above the composer in place
    /// across an inset change, updating `state` for the next change. Also
    /// called with an unchanged inset when `compensatesGrowth` turns true, to
    /// make up owed growth.
    static func shift(
        for inputs: ShiftInputs,
        state: inout ShiftState
    ) -> Shift? {
        guard inputs.isOffsetShiftAvailable else {
            // Nothing to return to once the transcript restarts its hidden
            // anchor pass (or the shift is unsupported).
            state = ShiftState()
            return nil
        }

        let insetChange = inputs.newComponents.inset - inputs.oldComponents.inset
        let keyboardChange = inputs.newComponents.keyboardOffset - inputs.oldComponents.keyboardOffset
        let base = shiftBase(
            observedOffsetY: inputs.observedOffsetY,
            state: state,
            now: inputs.now
        )
        let maximumOffsetY = maximumOffsetY(
            observedOffsetY: inputs.observedOffsetY,
            bottomAnchorMaxY: inputs.bottomAnchorMaxY,
            viewportHeight: inputs.viewportHeight,
            insetChange: insetChange
        ) ?? .greatestFiniteMagnitude

        if keyboardChange < -changeTolerance {
            return keyboardReturn(
                for: inputs,
                keyboardShrink: -keyboardChange,
                baseOffsetY: base.offsetY,
                maximumOffsetY: maximumOffsetY,
                state: &state
            )
        }

        let growth = insetChange > changeTolerance ? insetChange : 0
        let keyboardGrowth = keyboardChange > changeTolerance ? keyboardChange : 0
        guard inputs.compensatesGrowth else {
            if inputs.defersGrowth {
                state.owedKeyboardShift += keyboardGrowth
            }
            return nil
        }

        let owed = state.owedKeyboardShift
        state.owedKeyboardShift = 0
        let wanted = growth + owed
        guard wanted > changeTolerance else { return nil }

        // A base taken from an in-flight target was itself clamped to the
        // range, and this change grows the range by as much as it adds;
        // re-clamping would mix an offset and an anchor sample from different
        // animation frames and could stop a shift from the bottom short.
        let targetY = base.isPendingTarget
            ? base.offsetY + wanted
            : min(base.offsetY + wanted, maximumOffsetY)
        let amount = targetY - base.offsetY
        guard amount > changeTolerance else { return nil }

        state.outstandingKeyboardShift += min(amount, keyboardGrowth + owed)
        let isKeyboardDriven = keyboardGrowth > 0 || owed > changeTolerance
        return pendingShift(
            Shift(
                targetY: targetY,
                animationDuration: isKeyboardDriven ? inputs.keyboardAnimationDuration : nil,
                direction: .towardNewer
            ),
            now: inputs.now,
            state: &state
        )
    }

    /// The coordinator scrolled the transcript to the bottom
    /// (`ChatMessagesView.performBottomAnchor`): an unfinished shift's target
    /// is no longer where the content is headed, and growth owed from a
    /// covered keyboard is already made up (the newest content lands above
    /// the keyboard).
    static func coordinatorDidScroll(state: inout ShiftState) {
        state.pendingTargetY = nil
        state.owedKeyboardShift = 0
    }

    /// The reader took the scroll view over: an unfinished shift's target is
    /// no longer where the content is headed.
    static func userDidTakeOverScroll(state: inout ShiftState) {
        state.pendingTargetY = nil
    }

    private static func keyboardReturn(
        for inputs: ShiftInputs,
        keyboardShrink: CGFloat,
        baseOffsetY: CGFloat,
        maximumOffsetY: CGFloat,
        state: inout ShiftState
    ) -> Shift? {
        if inputs.isInteractiveDismissal {
            // The finger moved the content; there is no position to return to.
            state = ShiftState()
            return nil
        }
        // Growth that was never shifted for is paid down first: a sheet's
        // keyboard hiding must not return the composer's shift.
        let paidFromOwed = min(state.owedKeyboardShift, keyboardShrink)
        state.owedKeyboardShift -= paidFromOwed
        let amount = min(state.outstandingKeyboardShift, keyboardShrink - paidFromOwed)
        state.outstandingKeyboardShift -= amount
        guard amount > changeTolerance else { return nil }

        let targetY = max(0, min(baseOffsetY - amount, maximumOffsetY))
        guard baseOffsetY - targetY > changeTolerance else { return nil }
        return pendingShift(
            Shift(
                targetY: targetY,
                animationDuration: inputs.keyboardAnimationDuration,
                direction: .towardOlder
            ),
            now: inputs.now,
            state: &state
        )
    }

    private static func shiftBase(
        observedOffsetY: CGFloat,
        state: ShiftState,
        now: TimeInterval
    ) -> (offsetY: CGFloat, isPendingTarget: Bool) {
        guard let pendingTargetY = state.pendingTargetY,
              now < state.pendingSettlesAt else {
            return (observedOffsetY, false)
        }
        return (pendingTargetY, true)
    }

    private static func pendingShift(
        _ shift: Shift,
        now: TimeInterval,
        state: inout ShiftState
    ) -> Shift {
        state.pendingTargetY = shift.targetY
        state.pendingSettlesAt = now + shift.settleDuration
        return shift
    }
}
