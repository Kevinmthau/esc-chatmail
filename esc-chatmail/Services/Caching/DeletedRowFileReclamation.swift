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
enum DeletedRowFileReclamation {
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
