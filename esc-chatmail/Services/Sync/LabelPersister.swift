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

    /// Fetches labels by IDs within the given context.
    /// IMPORTANT: Call this inside a context.perform block to ensure thread safety.
    /// This is nonisolated because it must be called synchronously within context.perform.
    /// - Parameters:
    ///   - ids: Set of label IDs to fetch
    ///   - context: The Core Data context (must be on its queue)
    /// - Returns: Dictionary mapping label ID to Label object
    nonisolated func fetchLabelsByIds(_ ids: Set<String>, in context: NSManagedObjectContext) -> [String: Label] {
        guard !ids.isEmpty else { return [:] }
        let request = Label.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids)
        let labels: [Label]
        do {
            labels = try context.fetch(request)
        } catch {
            Log.error("Failed to fetch labels by IDs", category: .coreData, error: error)
            return [:]
        }
        // Duplicate-id Label rows are possible until the v4 constraint lands
        // (Label.id has no uniqueness constraint); collapse instead of
        // trapping — the maintenance merge pass repairs the store rows.
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
            // Same duplicate tolerance as fetchLabelsByIds: trapping here would
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
