import Foundation

/// Decisions the hidden initial-anchor pass (`ChatMessagesCoordinator`) makes
/// about whether the lazy stack has realized the transcript's tail, and how
/// to make it when it has not.
///
/// Why ("the chat opens blank until I scroll", persisting after #270 and
/// #280 closed every way the measured geometry could be wrong): the
/// transcript is a `LazyVStack` whose end is pinned while hidden
/// (`ChatTranscriptScrollAnchorPolicy`), so the first layout that carries
/// rows jumps the scroll view from the content top to its end in one step.
/// A lazy stack fills the visible rect from the rows it has placed and
/// estimates the rest; a jump into estimated territory can leave the rows
/// under the viewport unrealized, and a lazy stack draws nothing for an
/// unrealized row. SwiftUI's own geometry then reads as correct: the 1pt
/// trailing anchor and the stack's bounds end at the viewport bottom, so the
/// pass confirmed and revealed a blank transcript with no warning
/// (`isTrackedContentParkedPastEnd` reads the stack's claimed bounds). The
/// same structure, `ScrollView { LazyVStack } .defaultScrollAnchor(.bottom)`,
/// is reported with this symptom on Apple's developer forums (thread 741406:
/// first open fine, later opens blank, "once I scroll a little bit to the
/// top, messages appear like they just were scrolled", a plain `VStack` is
/// fine), and the report here predates the anchor roles: the pass's own
/// `scrollTo(bottomID, anchor: .bottom)` made the same jump before them.
///
/// Two consequences, which this policy encodes:
/// - Geometry alone cannot confirm a reveal. The signal that distinguishes a
///   filled viewport from an unfilled one is whether the newest row's view
///   is in the hierarchy (`VirtualScrollState.markRowRealized` from the
///   row's `onAppear`, `markRowUnrealized` from its `onDisappear`, keyed by
///   the row's `ForEach` identity so it survives the echo swap the view does
///   not remount for; a lazy stack calls them as it places and releases the
///   row, under the opaque cover as well, so the record is the row's current
///   placement). The pass waits for it at confirmation and at validation,
///   bounded as before by the retry budget and the time limit.
/// - A probe that scrolls to the offset the view is already at changes
///   nothing: `scrollTo(bottomID, anchor: .bottom)` targets the pinned end,
///   so under the pin it moves no pixel and hands the lazy stack no new rect.
///   The remedy is the reader's own: a real offset change. The nudge scrolls
///   the second-newest row's bottom to the viewport bottom, which is always a
///   different offset when the content exceeds the viewport (the newest row,
///   the spacer and the anchor lie below it), and the coordinator scrolls
///   back to the anchor one frame later. The stack fills the rect it was
///   moved to, and the return is a local move into realized rows, not a jump
///   into estimated ones. Both run unanimated under the cover.
///
/// A one-row window has no nudge target; it is also floored to the viewport
/// height, so it never jumps and is realized from the top.
enum ChatTranscriptRealizationPolicy {
    /// The probe scroll for a report that did not present the tail: the
    /// plain bottom-anchor scroll while the newest row is realized (the
    /// anchor was pushed off by growth, and `scrollTo` lands), the nudge
    /// when it is not (the anchor is unrealized, or realized at the end of
    /// an unfilled rect, and `scrollTo` to the pinned end is a no-op).
    static func probeKind(
        isNewestRowRealized: Bool
    ) -> ChatMessagesCoordinator.BottomAnchorStep.Kind {
        isNewestRowRealized ? .bottomAnchor : .realizationNudge
    }

    /// Index into the displayed rows of the row the nudge scrolls to, with
    /// anchor `.bottom`: the second-newest. Nil when the window has fewer
    /// than two rows, where no row's bottom sits above the content end.
    static func nudgeTargetIndex(rowCount: Int) -> Int? {
        guard rowCount >= 2 else { return nil }
        return rowCount - 2
    }
}
