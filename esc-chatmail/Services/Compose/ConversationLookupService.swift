import Foundation
import CoreData

/// Resolves active conversations by recipient set using participant hash matching.
@MainActor
struct ConversationLookupService {
    let context: NSManagedObjectContext

    func findActiveConversation(forRecipients recipients: [String]) -> Conversation? {
        let normalizedParticipants = Array(
            Set(recipients.map { EmailNormalizer.normalize($0) }.filter { !$0.isEmpty })
        )
        guard !normalizedParticipants.isEmpty else { return nil }

        let participantHash = calculateParticipantHash(from: normalizedParticipants)

        do {
            return try context.fetchActiveConversation(byParticipantHash: participantHash)
        } catch {
            Log.error("Failed to fetch active conversation by participant hash", category: .coreData, error: error)
            return nil
        }
    }
}
