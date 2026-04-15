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
    private struct ThreadConversationCandidate {
        let conversation: Conversation
        var containsForwardedMessage: Bool
    }

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
        let forwardingDetector = self.forwardingDetector

        return await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "gmThreadId == %@ AND conversation != nil", gmThreadId)
            request.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: false)]
            request.fetchBatchSize = 50
            request.returnsObjectsAsFaults = true
            request.relationshipKeyPathsForPrefetching = ["conversation"]

            do {
                let messages = try context.fetch(request)
                guard !messages.isEmpty else {
                    return nil
                }

                var orderedConversationIDs: [NSManagedObjectID] = []
                var candidatesByID: [NSManagedObjectID: ThreadConversationCandidate] = [:]
                orderedConversationIDs.reserveCapacity(4)
                candidatesByID.reserveCapacity(4)

                for message in messages {
                    guard let conversation = message.conversation else { continue }

                    let conversationID = conversation.objectID
                    let containsForwardedMessage = forwardingDetector(
                        message.subject,
                        [message.bodyText, message.cleanedSnippet, message.snippet]
                    )

                    if var existingCandidate = candidatesByID[conversationID] {
                        existingCandidate.containsForwardedMessage =
                            existingCandidate.containsForwardedMessage || containsForwardedMessage
                        candidatesByID[conversationID] = existingCandidate
                        continue
                    }

                    orderedConversationIDs.append(conversationID)
                    candidatesByID[conversationID] = ThreadConversationCandidate(
                        conversation: conversation,
                        containsForwardedMessage: containsForwardedMessage
                    )
                }

                let orderedCandidates = orderedConversationIDs.compactMap { candidatesByID[$0] }
                guard let existingConversation = Self.selectConversationForNonForwardedMessage(
                    from: orderedCandidates,
                    participantHash: participantHash
                ) else {
                    return nil
                }

                let existingParticipantHash = Self.trimmedParticipantHash(existingConversation.participantHash)

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

    private static func selectConversationForNonForwardedMessage(
        from candidates: [ThreadConversationCandidate],
        participantHash: String
    ) -> Conversation? {
        let nonForwardedCandidates = candidates.filter { !$0.containsForwardedMessage }
        guard !nonForwardedCandidates.isEmpty else { return nil }

        if let exactMatch = nonForwardedCandidates.first(where: {
            trimmedParticipantHash($0.conversation.participantHash) == participantHash
        }) {
            return exactMatch.conversation
        }

        if let candidateMissingHash = nonForwardedCandidates.first(where: {
            trimmedParticipantHash($0.conversation.participantHash).isEmpty
        }) {
            return candidateMissingHash.conversation
        }

        guard nonForwardedCandidates.count == 1 else {
            return nil
        }

        return nonForwardedCandidates[0].conversation
    }

    private static func trimmedParticipantHash(_ participantHash: String?) -> String {
        participantHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
