import Foundation
import CoreData

// MARK: - Statistics & Denormalization

extension DatabaseMaintenanceService {

    func updateDenormalizedFields() async {
        let context = coreDataStack.newBackgroundContext()

        await context.perform {
            // Update conversation message counts
            let conversationRequest = Conversation.fetchRequest()
            conversationRequest.fetchBatchSize = 50

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(conversationRequest)
            } catch {
                Log.error("Failed to fetch conversations for denormalization", category: .coreData, error: error)
                return
            }

            for conversation in conversations {
                // Update unread count
                let unreadMessages = (conversation.messages as? NSSet)?
                    .compactMap { $0 as? Message }
                    .filter { $0.isUnread }
                    .count ?? 0
                conversation.inboxUnreadCount = Int32(unreadMessages)
            }

            // Save denormalized data
            self.coreDataStack.saveIfNeeded(context: context)
            Log.info("Denormalized fields updated successfully", category: .coreData)
        }
    }

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
