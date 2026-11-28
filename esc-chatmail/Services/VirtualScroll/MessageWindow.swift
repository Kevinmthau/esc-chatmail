import Foundation
import CoreData

// MARK: - Message Window
struct MessageWindow {
    let startIndex: Int
    let endIndex: Int
    // Background fetches populate the window with stable object IDs only.
    // `VirtualScrollState` resolves these IDs on the viewContext before publishing
    // any `Message` instances to SwiftUI, which avoids leaking background-context
    // managed objects into UI state.
    var messageIDs: [NSManagedObjectID]
    var isLoading: Bool
    /// The row just above the window (`startIndex - 1`) and the row just below
    /// it (`endIndex`), where the load that built the window read them in the
    /// same query as its rows (`VirtualScrollMessagePage`) or a trim dropped
    /// them. The transcript's grouping reads those two rows on every publish
    /// (`VirtualScrollState.rowForGrouping`), and without their IDs that read
    /// was an OFFSET fetch on the main thread whose cost grows with the
    /// window's depth (architecture review 2026-11, chat-transcript-ui#2).
    /// Nil where nothing read the row, which keeps that fetch as the fallback:
    /// a window at the tail has no row below it, and a change that may have
    /// moved a row between the window and its neighbour clears both
    /// (`clearingNeighborIDs`). Not part of the window's rows: `messageIDs`
    /// stays exactly `startIndex..<endIndex`.
    var previousNeighborID: NSManagedObjectID?
    var nextNeighborID: NSManagedObjectID?

    init(
        startIndex: Int,
        endIndex: Int,
        messageIDs: [NSManagedObjectID],
        isLoading: Bool,
        previousNeighborID: NSManagedObjectID? = nil,
        nextNeighborID: NSManagedObjectID? = nil
    ) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.messageIDs = messageIDs
        self.isLoading = isLoading
        self.previousNeighborID = previousNeighborID
        self.nextNeighborID = nextNeighborID
    }

    var range: Range<Int> {
        startIndex..<endIndex
    }

    func contains(index: Int) -> Bool {
        range.contains(index)
    }

    /// The neighbour's ID at `index`, the row just outside either edge, or nil
    /// for any other index or a neighbour nothing read.
    func neighborID(atAbsoluteIndex index: Int) -> NSManagedObjectID? {
        if index == startIndex - 1 { return previousNeighborID }
        if index == endIndex { return nextNeighborID }
        return nil
    }

    /// The same window with neither neighbour known.
    func clearingNeighborIDs() -> MessageWindow {
        MessageWindow(
            startIndex: startIndex,
            endIndex: endIndex,
            messageIDs: messageIDs,
            isLoading: isLoading
        )
    }

    /// Returns a window whose row count is capped at `maxSize` by dropping
    /// rows from the BACK (largest absolute indices). Used when the window
    /// extends upward: the dropped rows are far below the viewport, so their
    /// removal cannot shift visible content. Preserves the invariant
    /// `endIndex - startIndex == messageIDs.count` that grouping and boundary
    /// math depend on. The first row dropped is the new window's next
    /// neighbour.
    func backTrimmed(to maxSize: Int) -> MessageWindow {
        guard maxSize > 0, messageIDs.count > maxSize else { return self }

        let overflow = messageIDs.count - maxSize
        return MessageWindow(
            startIndex: startIndex,
            endIndex: endIndex - overflow,
            messageIDs: Array(messageIDs.dropLast(overflow)),
            isLoading: isLoading,
            previousNeighborID: previousNeighborID,
            nextNeighborID: messageIDs[messageIDs.count - overflow]
        )
    }

    /// Returns a window whose row count is capped at `maxSize` by dropping
    /// rows from the FRONT (smallest absolute indices). Used while extending
    /// downward: the user's scroll position is near the back edge, so the
    /// removed rows are above the buffered viewport. Preserves the invariant
    /// `endIndex - startIndex == messageIDs.count`. The last row dropped is
    /// the new window's previous neighbour.
    func frontTrimmed(to maxSize: Int) -> MessageWindow {
        guard maxSize > 0, messageIDs.count > maxSize else { return self }

        let overflow = messageIDs.count - maxSize
        return MessageWindow(
            startIndex: startIndex + overflow,
            endIndex: endIndex,
            messageIDs: Array(messageIDs.dropFirst(overflow)),
            isLoading: isLoading,
            previousNeighborID: messageIDs[overflow - 1],
            nextNeighborID: nextNeighborID
        )
    }
}
