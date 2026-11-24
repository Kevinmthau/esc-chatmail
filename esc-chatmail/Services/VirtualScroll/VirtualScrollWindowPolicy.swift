import Foundation

/// The rows a scroll-driven window load asks for: the load
/// `VirtualScrollState.updateVisibleMessages` starts when the window does not
/// cover the reader's position, and the replay after a programmatic inset
/// shift, which reads from the same rows whether it would add rows above the
/// window (`VirtualScrollState.replayHeldVisibleIndex`). One definition for
/// both: a wider range in the load than in the replay's check prepends rows at
/// rest after a keyboard shift, which `deferredLeadingReplayIndex` exists to
/// prevent.
///
/// The position is the row whose view appeared last
/// (`VirtualScrollState.markIndexVisible`): the bottom edge while the reader
/// scrolls down, the top edge while they scroll up. It alone asks for
/// `bufferSize` rows above it and `visibleItemCount + bufferSize` from it
/// down, from one configuration on every platform, and an uncovered request
/// replaces the window (the sliding replace, which SwiftUI re-anchors while
/// the reader drags; measured on the iPhone simulator). A viewport showing
/// more rows than that reaches on the far side of the position, the Mac's
/// one-line rows of about 30 points in a tall chat column or an iPad, had
/// on-screen rows taken out of the `ForEach` by the replace: scrolling down,
/// every row more than `bufferSize` above the bottom edge, and scrolling up,
/// every row more than `visibleItemCount + bufferSize` below the top edge
/// (architecture review 2026-11, chat-transcript-ui#1). Near the tail that
/// leaves a window shorter than the viewport, which then cannot scroll.
///
/// So a request also keeps every row whose view is in the transcript's
/// hierarchy (`VirtualScrollState.realizedRowIdentities`), and on a side where
/// those reach past the position's rows, up to `bufferSize` rows beyond them:
/// without that slack the window ended at the viewport's edge, where a row
/// appearing there is within `preloadThreshold` of the window's end, and a
/// reader who turned back had no row beyond the edge to appear and move the
/// window (the iPhone keeps about 20 rows of it below the viewport while
/// scrolling up). Everything a request keeps beyond the position's rows is a
/// row the window already holds, so this adds no load, prepend or preload, and
/// it does not change whether a window covers the position (`positionRows`):
/// it changes only which rows a replace keeps. Where the realized rows lie
/// within the position's rows, as on a phone showing about ten, a replace is
/// exactly what it was.
///
/// Not growth on every step: extending the window at each step grew it to the
/// cap and front-trimmed rows far above the reader (iPhone simulator, 11 of 40
/// slow drags, `testMarkIndexVisible_withoutHold_slidesWindowAsBefore`), while
/// this keeps a span that moves with the viewport. Nor a larger buffer or
/// configuration for a tall viewport: every replace re-fetches and re-maps its
/// rows on the main actor, and the configuration also sets the initial window
/// and the window cap.
enum VirtualScrollWindowPolicy {
    /// Absolute rows `startIndex..<endIndex`. Not a `Range`: a position past
    /// the dataset's end (a count that shrank under it) gives an end below
    /// the start, which `VirtualScrollState.loadWindow` refuses, and
    /// constructing a `Range` from it would trap.
    struct Rows: Equatable {
        let startIndex: Int
        let endIndex: Int
    }

    /// What the reader's position alone asks for, clipped to the dataset. A
    /// window holding both its first and its last row needs no load.
    static func positionRows(
        scrollPosition: Int,
        totalCount: Int,
        configuration: VirtualScrollConfiguration
    ) -> Rows {
        Rows(
            startIndex: max(0, scrollPosition - configuration.bufferSize),
            endIndex: min(
                totalCount,
                scrollPosition + configuration.visibleItemCount + configuration.bufferSize
            )
        )
    }

    /// What a load for the reader's position asks for: `positionRows`,
    /// widened to keep `realizedRows`, the absolute rows whose views are in
    /// the hierarchy (`realizedRowSpan`), and on a side where those reach past
    /// the position's rows, up to `bufferSize` rows beyond them. Only rows of
    /// `windowRows`, the current window, are kept beyond the position's rows.
    /// A request past `maxWindowSize` drops the rows farthest from the
    /// position first, and never a row of `positionRows`, which the
    /// configuration keeps within the cap.
    static func requestedRows(
        scrollPosition: Int,
        totalCount: Int,
        configuration: VirtualScrollConfiguration,
        realizedRows: ClosedRange<Int>?,
        windowRows: Rows
    ) -> Rows {
        let position = positionRows(
            scrollPosition: scrollPosition,
            totalCount: totalCount,
            configuration: configuration
        )
        // A position past the end asks for nothing a load accepts; leave it
        // for `loadWindow` to refuse, as before.
        guard let realizedRows, position.startIndex <= position.endIndex else {
            return position
        }
        let heldStartIndex = max(0, windowRows.startIndex)
        let heldEndIndex = min(totalCount, windowRows.endIndex)
        let firstRealizedIndex = max(realizedRows.lowerBound, heldStartIndex)
        let lastRealizedIndex = min(realizedRows.upperBound, heldEndIndex - 1)
        guard firstRealizedIndex <= lastRealizedIndex else { return position }

        var startIndex = position.startIndex
        var endIndex = position.endIndex
        if firstRealizedIndex < startIndex {
            startIndex = max(heldStartIndex, firstRealizedIndex - configuration.bufferSize)
        }
        if lastRealizedIndex >= endIndex {
            endIndex = min(heldEndIndex, lastRealizedIndex + 1 + configuration.bufferSize)
        }

        var overflow = (endIndex - startIndex) - configuration.maxWindowSize
        while overflow > 0 {
            let canDropAbove = startIndex < position.startIndex
            let canDropBelow = endIndex > position.endIndex
            guard canDropAbove || canDropBelow else { break }
            let distanceAbove = scrollPosition - startIndex
            let distanceBelow = (endIndex - 1) - scrollPosition
            if canDropAbove && (!canDropBelow || distanceAbove >= distanceBelow) {
                startIndex += 1
            } else {
                endIndex -= 1
            }
            overflow -= 1
        }
        return Rows(startIndex: startIndex, endIndex: endIndex)
    }

    /// The absolute span, first to last, of the published rows whose views
    /// are in the hierarchy, each placed as the transcript places it: the
    /// window's start plus the row's place in the published rows
    /// (`VirtualScrollState.absoluteIndex(forVisibleIndex:)`, which the row's
    /// `markIndexVisible` reports from). Only rows inside the window count.
    /// Nil when no such row is realized.
    ///
    /// - Parameter publishedRowIdentities: the published rows' `ForEach`
    ///   identities in order (`ChatTranscriptIdentityPolicy.rows`), the
    ///   identities `realizedRowIdentities` is keyed by.
    static func realizedRowSpan(
        realizedRowIdentities: Set<ChatMessageDisplayIdentity>,
        publishedRowIdentities: [ChatMessageDisplayIdentity],
        windowRows: Rows
    ) -> ClosedRange<Int>? {
        guard !realizedRowIdentities.isEmpty else { return nil }
        var firstIndex: Int?
        var lastIndex: Int?
        for (rowIndex, rowIdentity) in publishedRowIdentities.enumerated()
        where realizedRowIdentities.contains(rowIdentity) {
            let absoluteIndex = windowRows.startIndex + rowIndex
            guard absoluteIndex < windowRows.endIndex else { break }
            firstIndex = min(firstIndex ?? absoluteIndex, absoluteIndex)
            lastIndex = max(lastIndex ?? absoluteIndex, absoluteIndex)
        }
        guard let firstIndex, let lastIndex else { return nil }
        return firstIndex...lastIndex
    }
}
