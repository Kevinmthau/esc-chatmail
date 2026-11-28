import Foundation
import CoreData

extension MessagePersister {
    /// Prefetches all label IDs for efficient lookups.
    /// Returns only IDs (Sendable) to avoid passing NSManagedObjects across async boundaries.
    func prefetchLabelIds(in context: NSManagedObjectContext) async -> Set<String> {
        return await context.perform {
            let request = Label.fetchRequest()
            request.fetchBatchSize = 100
            let labels: [Label]
            do {
                labels = try context.fetch(request)
            } catch {
                Log.error("Failed to prefetch label IDs", category: .coreData, error: error)
                return []
            }
            let ids = Set(labels.map { $0.id })
            Log.debug("Prefetched \(ids.count) label IDs", category: .sync)
            return ids
        }
    }

    /// The Label rows for `ids`, by ID. A read that fails throws, and never
    /// answers an empty dictionary: read as "none of Gmail's labels has a
    /// row", that stored a new message with no labels and stripped a stored
    /// one's (`createNewMessage`, `ExistingMessageLabelDiff`).
    /// Call inside the context's `perform`.
    nonisolated func fetchLabelsByIdsOrThrow(_ ids: Set<String>, in context: NSManagedObjectContext) throws -> [String: Label] {
        guard !ids.isEmpty else { return [:] }
        let request = Label.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids)
        let labels = try context.fetch(request)
        // Duplicate-id Label rows are possible (Label.id has no uniqueness
        // constraint); collapse instead of trapping. The maintenance merge
        // pass repairs the store rows.
        return Dictionary(labels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Saves labels from Gmail API to Core Data with upsert logic
    /// Labels are upserted by ID to prevent duplicate Label rows
    func saveLabels(_ gmailLabels: [GmailLabel], in context: NSManagedObjectContext) async {
        await context.perform {
            // Fetch all existing labels into a dictionary for efficient lookup
            let request = Label.fetchRequest()
            request.fetchBatchSize = 100
            let existingLabels: [Label]
            do {
                existingLabels = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch existing labels for save", category: .coreData, error: error)
                existingLabels = []
            }
            // Same duplicate tolerance as fetchLabelsByIdsOrThrow: trapping here would
            // crash every sync until the maintenance merge pass ran.
            var labelDict = Dictionary(existingLabels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            var insertedCount = 0
            var updatedCount = 0

            for gmailLabel in gmailLabels {
                if let existingLabel = labelDict[gmailLabel.id] {
                    // Update existing label if name changed
                    if existingLabel.name != gmailLabel.name {
                        existingLabel.name = gmailLabel.name
                        updatedCount += 1
                    }
                } else {
                    // Insert new label
                    guard let label = NSEntityDescription.insertNewObject(
                        forEntityName: "Label",
                        into: context
                    ) as? Label else {
                        Log.error("Failed to create Label entity", category: .coreData)
                        continue
                    }
                    label.id = gmailLabel.id
                    label.name = gmailLabel.name
                    labelDict[gmailLabel.id] = label
                    insertedCount += 1
                }
            }

            Log.debug("Labels: inserted=\(insertedCount), updated=\(updatedCount), total=\(labelDict.count)", category: .sync)
        }
    }
}
