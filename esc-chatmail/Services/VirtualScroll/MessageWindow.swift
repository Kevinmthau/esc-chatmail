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

    var range: Range<Int> {
        startIndex..<endIndex
    }

    func contains(index: Int) -> Bool {
        range.contains(index)
    }

    /// Returns a window whose row count is capped at `maxSize` by dropping
    /// rows from the BACK (largest absolute indices). Used when the window
    /// extends upward: the dropped rows are far below the viewport, so their
    /// removal cannot shift visible content. Preserves the invariant
    /// `endIndex - startIndex == messageIDs.count` that grouping and boundary
    /// math depend on.
    func backTrimmed(to maxSize: Int) -> MessageWindow {
        guard maxSize > 0, messageIDs.count > maxSize else { return self }

        let overflow = messageIDs.count - maxSize
        return MessageWindow(
            startIndex: startIndex,
            endIndex: endIndex - overflow,
            messageIDs: Array(messageIDs.dropLast(overflow)),
            isLoading: isLoading
        )
    }

    /// Returns a window whose row count is capped at `maxSize` by dropping
    /// rows from the FRONT (smallest absolute indices). Used while extending
    /// downward: the user's scroll position is near the back edge, so the
    /// removed rows are above the buffered viewport. Preserves the invariant
    /// `endIndex - startIndex == messageIDs.count`.
    func frontTrimmed(to maxSize: Int) -> MessageWindow {
        guard maxSize > 0, messageIDs.count > maxSize else { return self }

        let overflow = messageIDs.count - maxSize
        return MessageWindow(
            startIndex: startIndex + overflow,
            endIndex: endIndex,
            messageIDs: Array(messageIDs.dropFirst(overflow)),
            isLoading: isLoading
        )
    }
}
