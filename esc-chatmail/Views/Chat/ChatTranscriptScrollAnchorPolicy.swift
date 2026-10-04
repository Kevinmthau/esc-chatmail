import SwiftUI

/// Scroll anchors for the chat transcript's `ScrollView`, one per
/// `ScrollAnchorRole` (iOS 18 and later; below that `ChatMessagesView` keeps
/// the single `.top` anchor for every role).
///
/// Why the roles differ ("chats open slowly, and sometimes blank"). With one
/// `.top` anchor a chat opened at the top of its window: the lazy stack
/// realized and started loading the oldest rows first, and the coordinator's
/// hidden anchor pass had to find the bottom with a `scrollTo` before it could
/// confirm it. Under a `.top` size-change anchor, every bubble whose async load
/// finished above the 1pt bottom anchor pushed that anchor off the viewport
/// edge again, and the pass scrolled and re-confirmed from scratch
/// (`ChatMessagesCoordinator.handleBottomAnchorGeometryUpdate` resets its
/// retry budget on growth). The spinner therefore stayed up until the visible
/// bubbles stopped changing size, bounded only by the pass's time limit, and a
/// reveal at that limit landed wherever the last scroll had left the
/// transcript.
///
/// With the content end pinned while the transcript is hidden, the first
/// layout that carries rows lands on the newest ones, growth keeps them in
/// place, and the pass only confirms. Once revealed, size changes anchor at
/// the top again: `ChatBottomInsetPolicy` relies on inset growth adding space
/// below the viewport without moving the offset, and the coordinator's
/// post-reveal bottom follow reads growth as the anchor moving offscreen.
///
/// Assumes the transcript is presented at its end
/// (`ChatMessagesCoordinator.InitialPresentationAnchor.bottom`, the only value
/// `ChatMessagesSession` passes): a `.top` presentation reveals without an
/// anchor pass and would disagree with the content-end pinning below.
enum ChatTranscriptScrollAnchorPolicy {
    /// Where the scroll view starts before any size change: at its end. The
    /// first layout usually carries no rows yet (the window is still loading),
    /// so `sizeChanges(isTranscriptRevealed:)` does the work; this keeps a
    /// window that is already published on first layout at its end as well.
    /// Not a fallback on its own: without the hidden-transcript `.bottom`
    /// size-change anchor, a window published after the first layout lands
    /// at its oldest rows again.
    static let initialOffset: UnitPoint = .bottom

    /// Content shorter than the viewport is floored to the viewport height
    /// (`frame(minHeight:)` in `ChatMessagesView`), so this anchor never
    /// applies; `.top` matches the single anchor the transcript used before
    /// the roles were split.
    static let alignment: UnitPoint = .top

    /// The anchor kept in place when the content size changes.
    ///
    /// - Parameter isTranscriptRevealed: `ChatMessagesView.isTranscriptRevealed`
    ///   (the initial window has loaded and
    ///   `ChatMessagesCoordinator.isReadyToShow`), false during the hidden
    ///   anchor pass (first open and the empty-to-loaded restart alike). The
    ///   view passes the same value to `ChatBottomInsetPolicy`'s shift
    ///   availability, so the `.top` premise above and the shift agree.
    static func sizeChanges(isTranscriptRevealed: Bool) -> UnitPoint {
        isTranscriptRevealed ? .top : .bottom
    }
}
