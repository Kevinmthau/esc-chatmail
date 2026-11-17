import CoreData
import Foundation

/// The two questions asked before a deleted row's file is removed, and the reads that
/// answer the first.
///
/// The removal runs some time after the save that deleted the row: the plan crosses to the
/// main actor and then to a task. In that time the same Gmail message can be stored again
/// (taken out of Trash or Spam, then synced), under the same file name. So a file is
/// removed only where both hold:
///
/// - No stored row names it (`liveMessageIDs`, `referencedAttachmentPaths`). This is the
///   row that was saved again.
/// - It was not written after the delete (`wasWrittenAfter`). This is the row that is
///   being saved again: its file is written first and its row is saved with the rest of
///   its batch, so for that long the store has no row for a file that is the new one.
///
/// A read that fails is not an answer of "no row": the caller removes nothing, and the
/// daily orphan sweeps take the files later.
///
/// And an attachment file stored under an ID the app made is not removed with its row at
/// all (`isRemovedWithItsRow`); the orphan sweep takes it once no row names it.
enum DeletedRowFileReclamation {
    /// Whether a deleted attachment row's file is removed with the row. Not where it is stored
    /// under an ID the app made (`AttachmentPaths.isStoredUnderLocalID`): what the user added
    /// to a message, a forward's copy, or the preview of one.
    ///
    /// Such a file cannot be downloaded again, and the rows that delete it most often are an
    /// optimistic send's, when sync replaces them with the sent message
    /// (`MessagePersister.handoffOptimisticAttachmentStorage` and the ambiguous rows next to
    /// it). That replacement deliberately leaves the old files in place for the orphan sweep,
    /// because Quick Look keeps the URL it was given and may have one of them open; removed
    /// with the row, an open preview of a photo just sent lost its file. The orphan sweep
    /// also knows what this removal cannot: the files an unsaved draft holds (the compose
    /// leases) and those written within its grace period.
    static func isRemovedWithItsRow(_ relativePath: String) -> Bool {
        !AttachmentPaths.isStoredUnderLocalID(relativePath)
    }

    /// The message IDs among `ids` that a stored `Message` row has.
    static func liveMessageIDs(
        among ids: Set<String>,
        in context: NSManagedObjectContext
    ) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSDictionary>(entityName: "Message")
            request.predicate = NSPredicate(format: "id IN %@", ids)
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            return Set(try context.fetch(request).compactMap { $0["id"] as? String })
        }
    }

    /// The paths among `relativePaths` that a stored `Attachment` row names, as its file
    /// or as its preview. An attachment-scoped path can be shared by sibling messages, so a
    /// deleted row's path can still be another row's.
    static func referencedAttachmentPaths(
        among relativePaths: [String],
        in context: NSManagedObjectContext
    ) throws -> Set<String> {
        guard !relativePaths.isEmpty else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSDictionary>(entityName: "Attachment")
            request.predicate = NSPredicate(
                format: "localURL IN %@ OR previewURL IN %@",
                relativePaths,
                relativePaths
            )
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["localURL", "previewURL"]
            let asked = Set(relativePaths)
            var referenced: Set<String> = []
            for row in try context.fetch(request) {
                for key in ["localURL", "previewURL"] {
                    if let path = row[key] as? String, asked.contains(path) {
                        referenced.insert(path)
                    }
                }
            }
            return referenced
        }
    }

    /// Whether the file at `url` was last written after `date`. False for a file that is
    /// not there or whose date cannot be read: a delete of a missing file does nothing,
    /// and the stored-row check has already been passed.
    static func wasWrittenAfter(_ date: Date, fileAt url: URL) -> Bool {
        guard let modified = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else {
            return false
        }
        return modified > date
    }
}
