import Foundation

/// What `ChatMessagesView` shows, covers and lets through while the
/// transcript's initial window loads and the coordinator's hidden anchor pass
/// runs, and what it tells the virtual window about that pass.
///
/// The view has two signals to go on: the window's
/// `VirtualScrollState.InitialLoadPhase` and the coordinator's
/// `ChatMessagesCoordinator.isReadyToShow`. It needs several different
/// readings of them (the cover, two touch gates, the scroll anchors, the inset
/// shift), and the differences are deliberate: each exists for a state in
/// which the two signals disagree, which is mostly a revealed transcript that
/// has no rows (`.empty`, `.failed`, or `.loading` again after an empty
/// reveal). Written out where each was used, they were five expressions in
/// four places with nothing saying how they relate. They are one value here,
/// so the relations between them can be read side by side and tested over
/// every state (`ChatTranscriptPresentationPolicyTests`).
///
/// The view still owns when each reading is applied; this decides only what
/// it is.
enum ChatTranscriptPresentationPolicy {
    /// The readings of one (load phase, reveal, rows) state.
    struct Presentation: Equatable {
        /// The opaque cover is over the transcript, which is also hidden from
        /// accessibility: the window is still loading, has nothing to show
        /// (`.empty`, `.failed`), or has rows the hidden anchor pass has not
        /// revealed yet.
        let coversTranscript: Bool
        /// The cover is up over published rows the anchor pass has not
        /// revealed. The load overlay shows its placeholder for it as it
        /// does for `.loading`. False for a hidden transcript with no rows:
        /// there is no pass to wait for until rows exist.
        let isWaitingForInitialAnchor: Bool
        /// The scroll view takes touches: once the window has loaded with
        /// rows. That includes the hidden anchor pass, on purpose. A drag
        /// during it must reach the scroll view's gesture, which reveals the
        /// rows and cancels further forced anchoring, the reader's way out of
        /// a pass that is taking long.
        let scrollViewTakesTouches: Bool
        /// The rows take taps and long presses: only once the coordinator
        /// has revealed them. Bubbles under the cover must not take a tap
        /// (opening the reader) or a long press (lifting a context-menu
        /// preview) the reader cannot see. Scrolling is the scroll view's own
        /// gesture and is not gated by this.
        let rowsTakeTouches: Bool
        /// What `ChatTranscriptScrollAnchors` is told: the coordinator's
        /// reveal alone, not `isRevealedForInsetChanges`. The two differ
        /// only while a revealed transcript has no rows, where the
        /// transcript always kept its `.top` size-change anchor. Pinning the
        /// end there instead parked a chat emptied while open past its
        /// content end once the composer and keyboard outgrew the viewport,
        /// and left it scrolled away from the top when a screenful of rows
        /// came back (measured in a replica of the transcript's scroll
        /// structure on the iOS 27.0 simulator, not in the app).
        let anchorsTreatTranscriptAsRevealed: Bool
        /// The initial window has loaded and the coordinator has revealed
        /// it. The one definition of "revealed" for the inset shift
        /// (`ChatBottomInsetPolicy.isOffsetShiftAvailable`) and the spacer
        /// transition (`ChatBottomInsetPolicy.spacerTransition`). It implies
        /// `anchorsTreatTranscriptAsRevealed`: whenever a shift is available
        /// the transcript has the `.top` size-change anchor
        /// `ChatBottomInsetPolicy` assumes.
        let isRevealedForInsetChanges: Bool
    }

    /// - Parameters:
    ///   - initialLoadPhase: `VirtualScrollState.initialLoadPhase`.
    ///   - isReadyToShow: `ChatMessagesCoordinator.isReadyToShow`.
    ///   - hasDisplayedRows: the window has published at least one row.
    static func presentation(
        initialLoadPhase: VirtualScrollState.InitialLoadPhase,
        isReadyToShow: Bool,
        hasDisplayedRows: Bool
    ) -> Presentation {
        let isWaitingForInitialAnchor = !isReadyToShow && hasDisplayedRows
        return Presentation(
            coversTranscript: initialLoadPhase != .loaded || isWaitingForInitialAnchor,
            isWaitingForInitialAnchor: isWaitingForInitialAnchor,
            scrollViewTakesTouches: initialLoadPhase == .loaded,
            rowsTakeTouches: isReadyToShow,
            anchorsTreatTranscriptAsRevealed: isReadyToShow,
            isRevealedForInsetChanges: initialLoadPhase == .loaded && isReadyToShow
        )
    }

    /// Whether the transcript counts as resting at its bottom after a
    /// geometry report: the value the view keeps as its `isBottomAnchorVisible`
    /// and acts on. While it is true the virtual window follows the latest
    /// insertions (`VirtualScrollState.setFollowsLatestInsertions`), a new
    /// message scrolls into view (`ChatMessagesCoordinator.handleMessageCountChange`),
    /// and a message that arrives is marked read
    /// (`handleInsertedVisibleMessageEvent`, `handleLatestWindowLayout`).
    ///
    /// The 1pt anchor intersecting the viewport is not enough for any of
    /// those. Under the cover the anchor is on screen for the whole hidden
    /// pass and the reader has seen nothing. With a finger on the transcript,
    /// or while a scroll of theirs still owns it, the anchor passing through
    /// the viewport is the reader moving, not resting there.
    ///
    /// - Parameters:
    ///   - initialLoadPhase: `VirtualScrollState.initialLoadPhase`.
    ///   - isReadyToShow: `ChatMessagesCoordinator.isReadyToShow`, read after
    ///     the coordinator has handled the same report, which is where a
    ///     reveal happens.
    ///   - isUserScrollGestureActive: the transcript's drag gesture is down.
    ///   - isUserScrollTakeoverActive:
    ///     `ChatMessagesCoordinator.isUserScrollTakeoverActive`.
    ///   - isBottomAnchorInViewport: the anchor's frame is laid out and
    ///     intersects the viewport, as reported to the coordinator.
    static func isBottomAnchorVisibleForFollowing(
        initialLoadPhase: VirtualScrollState.InitialLoadPhase,
        isReadyToShow: Bool,
        isUserScrollGestureActive: Bool,
        isUserScrollTakeoverActive: Bool,
        isBottomAnchorInViewport: Bool
    ) -> Bool {
        initialLoadPhase == .loaded &&
            isReadyToShow &&
            !isUserScrollGestureActive &&
            !isUserScrollTakeoverActive &&
            isBottomAnchorInViewport
    }

    /// The moments at which the view reconsiders the virtual window's
    /// initial-anchor hold (`VirtualScrollState.isInitialAnchorHoldActive`).
    enum InitialAnchorHoldEvent: Equatable, CaseIterable {
        /// `ChatMessagesCoordinator.isReadyToShow` changed.
        case revealChanged
        /// The transcript appeared (again).
        case appeared
        /// The initial window was published (again): this follows every
        /// initial-window publish, each of which arms the hold for an
        /// end-anchored window.
        case initialWindowPublished
    }

    enum InitialAnchorHoldChange: Equatable {
        /// `VirtualScrollState.beginInitialAnchorHold()`.
        case begin
        /// `VirtualScrollState.endInitialAnchorHold()`.
        case end
    }

    /// What the view does to the initial-anchor hold at `event`, nil for
    /// nothing. The hold keeps row `onAppear` events from moving the virtual
    /// window while the hidden anchor pass runs, so it has to be armed for
    /// every pass and released at every reveal, or after one that will not
    /// be followed by another.
    ///
    /// - Parameters:
    ///   - isReadyToShow: `ChatMessagesCoordinator.isReadyToShow`; for
    ///     `.revealChanged`, the value it changed to.
    ///   - isRevealRestartableFromEmpty:
    ///     `ChatMessagesCoordinator.isRevealRestartableFromEmpty`.
    static func initialAnchorHoldChange(
        on event: InitialAnchorHoldEvent,
        isReadyToShow: Bool,
        isRevealRestartableFromEmpty: Bool
    ) -> InitialAnchorHoldChange? {
        switch event {
        case .revealChanged:
            // A reveal (confirmed, fallback, or user takeover) ends the hold
            // that kept pre-reveal onAppear events from mutating the
            // virtual-scroll window mid-anchor. The other direction is the
            // empty-to-loaded restart: it re-hides the transcript and re-runs
            // the hidden anchor pass over rows the latest window load
            // publishes, which gets the same hold the first-open pass has.
            return isReadyToShow ? .end : .begin
        case .appeared:
            // Re-appearing after a completed reveal publishes no
            // `isReadyToShow` change, so the hold is released here as well.
            return isReadyToShow ? .end : nil
        case .initialWindowPublished:
            // A re-publish of the initial window after a terminal reveal
            // (retry from the failure overlay, resume of an interrupted load)
            // re-arms the hold, but no `isReadyToShow` transition will ever
            // release it: the coordinator does not restart a reveal from a
            // non-empty ready state. Empty-conversation readiness is
            // excluded: the coordinator restarts from it when messages
            // arrive, and that restarted hidden pass needs the hold the
            // re-publish just armed.
            return isReadyToShow && !isRevealRestartableFromEmpty ? .end : nil
        }
    }
}
