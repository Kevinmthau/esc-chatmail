import Foundation
import CoreData

extension MessagePersister {
    /// Prefetches all label IDs for efficient lookups.
    /// Returns only IDs (Sendable) to avoid passing NSManagedObjects across async boundaries.
    func prefetchLabelIds(in context: NSManagedObjectContext) async -> Set<String> {
        return await context.perform {
            let request = Label.fetchRequest()
            request.fetchBatchSize = 100
            guard let labels = try? context.fetch(request) else {
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
        guard let labels = try? context.fetch(request) else { return [:] }
        return Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    }

    /// Prefetches all labels into a dictionary for efficient lookups
    /// @available(*, deprecated, message: "Use prefetchLabelIds instead to avoid passing NSManagedObjects across async boundaries")
    func prefetchLabels(in context: NSManagedObjectContext) async -> [String: Label] {
        return await context.perform {
            let request = Label.fetchRequest()
            request.fetchBatchSize = 100
            guard let labels = try? context.fetch(request) else {
                return [:]
            }
            var labelCache: [String: Label] = [:]
            for label in labels {
                labelCache[label.id] = label
            }
            Log.debug("Prefetched \(labelCache.count) labels into cache", category: .sync)
            return labelCache
        }
    }

    /// Saves labels from Gmail API to Core Data with upsert logic
    /// Labels are upserted by ID to prevent duplicate Label rows
    func saveLabels(_ gmailLabels: [GmailLabel], in context: NSManagedObjectContext) async {
        await context.perform {
            // Fetch all existing labels into a dictionary for efficient lookup
            let request = Label.fetchRequest()
            let existingLabels = (try? context.fetch(request)) ?? []
            var labelDict = Dictionary(uniqueKeysWithValues: existingLabels.map { ($0.id, $0) })

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
                    let label = NSEntityDescription.insertNewObject(
                        forEntityName: "Label",
                        into: context
                    ) as! Label
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
