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
}
