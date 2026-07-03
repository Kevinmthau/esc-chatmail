import Foundation
import CoreData

// MARK: - Statistics

extension DatabaseMaintenanceService {

    func getDatabaseStatistics() async -> DatabaseStatistics {
        let context = coreDataStack.newBackgroundContext()

        let stats = await context.perform {
            let messageCount = (try? context.count(for: Message.fetchRequest())) ?? 0
            let conversationCount = (try? context.count(for: Conversation.fetchRequest())) ?? 0
            let attachmentCount = (try? context.count(for: Attachment.fetchRequest())) ?? 0
            let personCount = (try? context.count(for: Person.fetchRequest())) ?? 0

            // Calculate database size
            var databaseSize: Int64 = 0
            if let storeURL = self.coreDataStack.persistentContainer.persistentStoreDescriptions.first?.url {
                let fileManager = FileManager.default
                if let attributes = try? fileManager.attributesOfItem(atPath: storeURL.path) {
                    databaseSize = attributes[.size] as? Int64 ?? 0
                }
            }

            return (
                messageCount: messageCount,
                conversationCount: conversationCount,
                attachmentCount: attachmentCount,
                personCount: personCount,
                databaseSize: databaseSize
            )
        }

        return DatabaseStatistics(
            messageCount: stats.messageCount,
            conversationCount: stats.conversationCount,
            attachmentCount: stats.attachmentCount,
            personCount: stats.personCount,
            databaseSize: stats.databaseSize,
            lastMaintenanceDate: self.lastMaintenanceDate
        )
    }
}
