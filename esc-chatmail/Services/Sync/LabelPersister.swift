import Foundation
import CoreData

extension MessagePersister {
    /// Prefetches all labels into a dictionary for efficient lookups
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
