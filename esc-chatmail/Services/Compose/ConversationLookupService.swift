import Foundation
import CoreData

/// Resolves active conversations by recipient set using participant hash matching.
@MainActor
struct ConversationLookupService {
    let context: NSManagedObjectContext

    func findActiveConversation(forRecipients recipients: [String], myAliases: Set<String>) -> Conversation? {
        guard let identity = makeRecipientParticipantSetIdentity(
            recipients: recipients,
            myAliases: myAliases
        ) else { return nil }

        do {
            return try context.fetchActiveConversation(byParticipantHash: identity.participantHash)
        } catch {
            Log.error("Failed to fetch active conversation by participant hash", category: .coreData, error: error)
            return nil
        }
    }
}
