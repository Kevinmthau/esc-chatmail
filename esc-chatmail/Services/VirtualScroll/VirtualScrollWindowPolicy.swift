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
/// every row `visibleItemCount + bufferSize` or more below the top edge
/// (architecture review 2026-11, chat-transcript-ui#1). Near the tail that
/// leaves a window shorter than the viewport, which then cannot scroll.
///
/// So a request also keeps the rows whose views are in the transcript's
/// hierarchy (`VirtualScrollState.realizedRowIdentities`) in an unbroken run
/// on from the position's rows, and on a side where that run reaches past
/// them, up to `bufferSize` rows beyond it: without that slack the window
/// ended at the viewport's edge, where a row appearing there is within
/// `preloadThreshold` of the window's end, and a reader who turned back had no
/// row beyond the edge to appear and move the window (the iPhone keeps about
/// 20 rows of it below the viewport while scrolling up). A viewport whose edge
/// is exactly the position rows' edge keeps no slack there, as before: it
/// reaches no further than the position's rows. Only a run on from
/// the position's rows: the rows on screen are one, while a realized row
/// apart from it is a record the view has not cleared yet (an `onDisappear`
/// still to come after a jump, or one never delivered), and keeping its row
/// kept the window from sliding past it until the cap trimmed it.
///
/// Everything a request keeps beyond the position's rows is a row the window
/// already holds, so this adds no load or prepend, and it does not change
/// whether a window covers the position (`positionRows`): it changes only
/// which rows a replace keeps. The preloads read only the position and the
/// window's edges, which are at least as far from it as before. Where no
/// realized row lies just past the position's rows a replace is exactly what
/// it was: scrolling down, no more than `bufferSize` rows realized above the
/// bottom edge, about ten on a phone. A phone that realizes more (short rows
/// on a Pro Max, a small text size) widens as a tall viewport does, which has
/// not been measured on a phone. What a wider replace costs is its rows: every
/// replace re-fetches and re-maps all of them on the main actor, about 70
/// instead of 40 for a Mac viewport of 33 rows.
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
    /// the dataset's end (a count that shrank under it) gives an end at or
    /// below the start, which `VirtualScrollState.loadWindow` fails without
    /// publishing, and constructing a `Range` from an end below the start
    /// would trap.
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
    /// widened to keep the rows of `realizedRows` (absolute indices of the
    /// rows whose views are in the hierarchy, `realizedRowIndices`) that run
    /// on unbroken from it, and on a side where that run reaches past the
    /// position's rows, up to `bufferSize` rows beyond it. Only rows of
    /// `windowRows`, the current window, are kept beyond the position's rows.
    /// A request past `maxWindowSize` drops the rows farthest from the
    /// position first, and never a row of `positionRows`, which the
    /// configuration keeps within the cap.
    static func requestedRows(
        scrollPosition: Int,
        totalCount: Int,
        configuration: VirtualScrollConfiguration,
        realizedRows: Set<Int>,
        windowRows: Rows
    ) -> Rows {
        let position = positionRows(
            scrollPosition: scrollPosition,
            totalCount: totalCount,
            configuration: configuration
        )
        // A position at or past the end asks for nothing a load accepts (an
        // empty or inverted range); leave it for `loadWindow` to fail, as
        // before, rather than widen it into a load that succeeds.
        guard !realizedRows.isEmpty, position.startIndex < position.endIndex else {
            return position
        }
        let heldStartIndex = max(0, windowRows.startIndex)
        let heldEndIndex = min(totalCount, windowRows.endIndex)

        // The realized rows running on from the position's rows, each way.
        var runStartIndex = position.startIndex
        while runStartIndex - 1 >= heldStartIndex, realizedRows.contains(runStartIndex - 1) {
            runStartIndex -= 1
        }
        var runEndIndex = position.endIndex
        while runEndIndex < heldEndIndex, realizedRows.contains(runEndIndex) {
            runEndIndex += 1
        }

        var startIndex = position.startIndex
        var endIndex = position.endIndex
        if runStartIndex < startIndex {
            startIndex = max(heldStartIndex, runStartIndex - configuration.bufferSize)
        }
        if runEndIndex > endIndex {
            endIndex = min(heldEndIndex, runEndIndex + configuration.bufferSize)
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

    /// The absolute indices of the published rows whose views are in the
    /// hierarchy, each placed as the transcript places it: the window's start
    /// plus the row's place in the published rows
    /// (`VirtualScrollState.absoluteIndex(forVisibleIndex:)`, which the row's
    /// `markIndexVisible` reports from). Only rows inside the window count.
    ///
    /// - Parameter publishedRowIdentities: the published rows' `ForEach`
    ///   identities in order (`ChatTranscriptIdentityPolicy.rows`), the
    ///   identities `realizedRowIdentities` is keyed by.
    static func realizedRowIndices(
        realizedRowIdentities: Set<ChatMessageDisplayIdentity>,
        publishedRowIdentities: [ChatMessageDisplayIdentity],
        windowRows: Rows
    ) -> Set<Int> {
        guard !realizedRowIdentities.isEmpty else { return [] }
        var indices = Set<Int>()
        for (rowIndex, rowIdentity) in publishedRowIdentities.enumerated()
        where realizedRowIdentities.contains(rowIdentity) {
            let absoluteIndex = windowRows.startIndex + rowIndex
            guard absoluteIndex < windowRows.endIndex else { break }
            indices.insert(absoluteIndex)
        }
        return indices
    }
}
