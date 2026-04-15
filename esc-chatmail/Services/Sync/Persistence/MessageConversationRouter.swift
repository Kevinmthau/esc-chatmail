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

    func resolveConversationObjectID(
        for processedMessage: ProcessedMessage,
        myAliases: Set<String>,
        in context: NSManagedObjectContext
    ) async throws -> NSManagedObjectID {
        let shouldReactivateConversation = processedMessage.labelIds.contains("INBOX")

        let identity = conversationManager.createConversationIdentity(
            from: processedMessage.headers,
            gmThreadId: processedMessage.gmThreadId,
            myAliases: myAliases
        )

        if shouldReuseConversationByThread(for: processedMessage),
           let existingConversationObjectID = await findExistingConversationObjectID(
                forGmThreadId: processedMessage.gmThreadId,
                participantHash: identity.participantHash,
                reactivateArchivedIfNeeded: shouldReactivateConversation,
                in: context
           ) {
            return existingConversationObjectID
        }

        return try await conversationManager.findOrCreateConversationObjectID(
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
    private func findExistingConversationObjectID(
        forGmThreadId gmThreadId: String,
        participantHash: String,
        reactivateArchivedIfNeeded: Bool,
        in context: NSManagedObjectContext
    ) async -> NSManagedObjectID? {
        guard !gmThreadId.isEmpty else { return nil }

        return await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "gmThreadId == %@ AND conversation != nil", gmThreadId)
            request.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: false)]
            request.fetchLimit = 1
            request.fetchBatchSize = 1
            request.returnsObjectsAsFaults = true
            request.relationshipKeyPathsForPrefetching = ["conversation"]

            do {
                guard let existingConversation = try context.fetch(request).first?.conversation else {
                    return nil
                }

                let existingParticipantHash = existingConversation.participantHash?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if existingParticipantHash.isEmpty {
                    existingConversation.participantHash = participantHash
                } else if existingParticipantHash != participantHash {
                    Log.info(
                        "Reusing gmThreadId conversation despite participantHash mismatch for non-forwarded message",
                        category: .conversation
                    )
                }

                if reactivateArchivedIfNeeded, existingConversation.archivedAt != nil {
                    existingConversation.archivedAt = nil
                    existingConversation.hidden = false
                }

                return existingConversation.objectID
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
}
