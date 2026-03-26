import Foundation
import CoreData

/// Resolves which conversation a newly persisted message should belong to.
///
/// The routing rules are intentionally centralized here because they combine:
/// - Gmail thread reuse
/// - forward-branch detection
/// - archived conversation reactivation
/// - participant-based fallback identity
final class MessageConversationRouter {
    private let conversationManager: ConversationManager
    private let forwardingDetector: @Sendable (_ subject: String?, _ contentCandidates: [String?]) -> Bool

    init(
        conversationManager: ConversationManager = ConversationManager(),
        forwardingDetector: @escaping @Sendable (_ subject: String?, _ contentCandidates: [String?]) -> Bool = { subject, candidates in
            ForwardingHeuristics.indicatesForwarding(subject: subject, contentCandidates: candidates)
        }
    ) {
        self.conversationManager = conversationManager
        self.forwardingDetector = forwardingDetector
    }

    func resolveConversation(
        for processedMessage: ProcessedMessage,
        myAliases: Set<String>,
        in context: NSManagedObjectContext
    ) async throws -> Conversation {
        let shouldReactivateConversation = processedMessage.labelIds.contains("INBOX")

        let identity = conversationManager.createConversationIdentity(
            from: processedMessage.headers,
            gmThreadId: processedMessage.gmThreadId,
            myAliases: myAliases
        )

        if shouldReuseConversationByThread(for: processedMessage),
           let existingConversation = findExistingConversation(
                forGmThreadId: processedMessage.gmThreadId,
                in: context
           ) {
            // Check if participants changed (e.g. someone new was CC'd).
            // When that happens, create a new conversation for the expanded group
            // instead of reusing the existing one.
            if existingConversation.participantHash == identity.participantHash {
                if shouldReactivateConversation, existingConversation.archivedAt != nil {
                    existingConversation.archivedAt = nil
                    existingConversation.hidden = false
                }
                return existingConversation
            }
        }

        return try await conversationManager.findOrCreateConversation(
            for: identity,
            initialLastMessageDate: processedMessage.internalDate,
            reactivateArchivedIfNeeded: shouldReactivateConversation,
            in: context
        )
    }

    private func shouldReuseConversationByThread(for processedMessage: ProcessedMessage) -> Bool {
        guard !processedMessage.gmThreadId.isEmpty else { return false }

        let isForwardedMessage = forwardingDetector(
            processedMessage.headers.subject,
            [
                processedMessage.plainTextBody,
                processedMessage.htmlBody,
                processedMessage.cleanedSnippet,
                processedMessage.snippet
            ]
        )

        return !isForwardedMessage
    }

    /// Finds an existing conversation for a Gmail thread by looking up any already-persisted
    /// message with the same `gmThreadId`.
    ///
    /// This keeps a single Gmail thread grouped together unless a forward branch is detected.
    private func findExistingConversation(
        forGmThreadId gmThreadId: String,
        in context: NSManagedObjectContext
    ) -> Conversation? {
        guard !gmThreadId.isEmpty else { return nil }

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "gmThreadId == %@ AND conversation != nil", gmThreadId)
        request.fetchLimit = 1
        request.fetchBatchSize = 1
        request.returnsObjectsAsFaults = true
        request.relationshipKeyPathsForPrefetching = ["conversation"]

        do {
            return try context.fetch(request).first?.conversation
        } catch {
            Log.error(
                "Failed to fetch existing conversation for gmThreadId \(gmThreadId.prefix(16))...",
                category: .coreData,
                error: error
            )
            return nil
        }
    }
}
