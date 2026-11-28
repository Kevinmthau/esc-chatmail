import Foundation

/// Whether a change of text size arms a fresh bounded bottom follow on the chat transcript
/// (architecture review 2026-11, gap-accessibility-architecture#4).
///
/// A revealed transcript keeps its top in place when its content grows
/// (`ChatTranscriptScrollAnchorPolicy.sizeChanges`). Once the post-reveal follow has expired
/// (about 3 s after the last growth, 30 s at most), the rows and the composer a larger text size
/// grows push the newest message under the composer, nothing answers, and latest-following stays
/// off until the reader scrolls or focuses the field. A reader who was at the bottom gets a fresh
/// follow, the post-send follow's shape (3 s grace, slid by growth up to 30 s, cancelled by a
/// scroll), which answers that growth as it answers a bubble's late load. Only the change of size
/// arms one: an expired follow stays deaf to ordinary growth. In a throwaway hosted mount of the
/// real transcript (60 text rows, an iPhone window, the size raised to accessibility Large by a
/// trait override, iOS 27.0 simulator, 2026-11-28) the visible bottom stayed 1,261 points above
/// the content's end without the follow, and was at the end within half a second with it.
///
/// Decided at the first geometry report under the new size, from the reading before it, never in
/// `onChange(of: dynamicTypeSize)`. On the iOS 27.0 simulator (2026-11-28, a throwaway hosted
/// probe of the transcript's scroll and anchor structure, the size changed by a window trait
/// override and by `simctl ui content_size` alike) the report carrying the growth ran first, in
/// the same update. By the `onChange` the anchor already read as pushed off, so nothing there
/// told a reader who had been at the bottom from one reading history.
enum ChatTranscriptTextSizeFollowPolicy {
    /// - Parameters:
    ///   - wasBottomAnchorVisible: The bottom anchor was in the viewport in the report before the
    ///     change. Required on its own, not only the absence of a takeover: only the transcript's
    ///     drag sets the takeover, and a trackpad, a mouse wheel or a VoiceOver scroll does not,
    ///     so a reader moved into history that way would be pulled back to the bottom.
    ///   - isTranscriptRevealed: The hidden initial-anchor pass has ended. It owns scrolling
    ///     until the reveal, and a follow armed while it is pending takes every geometry report
    ///     before the pass sees it. A window that loads again after the reveal has no rows, so it
    ///     needs no term of its own.
    ///   - isChatVisible: The chat has appeared and not disappeared.
    ///   - isUserScrollTakeoverActive: The reader dragged the transcript and has not come back to
    ///     the bottom.
    ///   - isUserScrollInteractionActive: A finger is on the transcript.
    ///   - isScrollPhaseUserDriven: The scroll view is in a user-driven scroll phase (iOS 26+).
    ///
    /// No term for a compensated shift: while its hold stands, a report with a follow armed is
    /// left to the hold's settle check (`ChatMessagesCoordinator.handleBottomAnchorGeometryUpdate`),
    /// so the follow armed here starts no scroll of its own during the shift.
    static func armsFollow(
        wasBottomAnchorVisible: Bool,
        isTranscriptRevealed: Bool,
        isChatVisible: Bool,
        isUserScrollTakeoverActive: Bool,
        isUserScrollInteractionActive: Bool,
        isScrollPhaseUserDriven: Bool
    ) -> Bool {
        wasBottomAnchorVisible
            && isTranscriptRevealed
            && isChatVisible
            && !isUserScrollTakeoverActive
            && !isUserScrollInteractionActive
            && !isScrollPhaseUserDriven
    }
}
