import Foundation

/// The body file a deleted message leaves: what `CacheCoordinator` reads off the deleted row
/// while its save is being posted, and what `HTMLContentHandler.deleteHTML(forDeleted:…)`
/// is later given to remove.
struct DeletedMessageBody: Sendable, Hashable {
    let messageId: String
    /// The row's stored body location, where it is not the message's own file in the
    /// Messages directory.
    let bodyStorageURI: String?
}
