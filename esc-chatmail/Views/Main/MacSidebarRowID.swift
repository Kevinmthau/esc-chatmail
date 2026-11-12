import CoreData

/// A conversation row's identity in the Mac sidebar's list (`MacConversationSidebar`): the
/// conversation's object ID, held in a Swift value.
///
/// The list must never be given the `NSManagedObjectID` itself as a row's id. On the Mac a
/// SwiftUI `List` is an `NSTableView`, and with ids of that class the table draws the wrong rows
/// as soon as one row moves. That is what the first native build did (build 528, 2026-11-12):
/// once a sync had moved conversations to the top, the sidebar showed conversations twice, left
/// rows at positions they had moved away from, and a click opened another chat than the row
/// showed.
///
/// Measured 2026-11-12 on macOS 27.2, with the real sidebar in the Mac test host and in a
/// throwaway program with no app code. A `List` of 100 rows identified by `NSManagedObjectID`,
/// and the row at index 13 moved to index 0:
/// - Each of rows 0 to 13 then drew the row that stands at its *old* index in the new order. So
///   "row 12" was drawn at the top, where the moved row belongs, and was missing lower down.
///   SwiftUI's own row objects still carried their old row numbers.
/// - The table's rows themselves were right: the row at each index was the one the data has
///   there. Only what the row drew was wrong, which is why a click selected a conversation the
///   row did not show.
/// - It did not need the sidebar: plain `Text` rows, with or without a selection, in the
///   `.inset` style or the default one. It did not need a burst either. One move was enough.
/// - It was the same with object IDs from a SQLite store, from an in-memory store and with
///   temporary ones, and with `NSUUID` and `NSString` ids.
/// - It did not happen with this type, with the id's URI as a `URL`, with a Swift class, or with
///   an `NSObject` subclass written in Swift.
/// - It did not happen either when the `ForEach`'s content was an `if`/`else`. The probes
///   written to find this fault built their rows that way, and missed it through hundreds of
///   moves. A probe of a list must give the `ForEach` the row and nothing around it.
///
/// So the id is a struct, and everything outside the list goes on using the object ID: the
/// mailbox's selection (`MacMailboxView`), the policies and the view model. The sidebar converts
/// at the list's edge, with the two functions below.
struct MacSidebarRowID: Hashable {
    let conversationID: NSManagedObjectID

    /// The list's selection, from the mailbox's.
    static func rowIDs(for conversationIDs: Set<NSManagedObjectID>) -> Set<MacSidebarRowID> {
        Set(conversationIDs.map(MacSidebarRowID.init(conversationID:)))
    }

    /// The mailbox's selection, from the list's.
    static func conversationIDs(for rowIDs: Set<MacSidebarRowID>) -> Set<NSManagedObjectID> {
        Set(rowIDs.map(\.conversationID))
    }
}

extension ConversationListItem {
    /// This row's id in the Mac sidebar's list. Not `id`: see `MacSidebarRowID`.
    var sidebarRowID: MacSidebarRowID {
        MacSidebarRowID(conversationID: id)
    }
}
