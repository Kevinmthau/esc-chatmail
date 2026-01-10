import Foundation
import CoreData

/// Facade for conversation management operations.
/// Delegates to specialized components for focused responsibilities:
/// - ConversationCreationSerializer: Thread-safe conversation creation
/// - ConversationRollupUpdater: Rollup calculations (lastMessageDate, snippet, hasInbox)
/// - ConversationMerger: Duplicate detection and merging
final class ConversationManager: Sendable {
    private let rollupUpdater: ConversationRollupUpdater
    private let merger: ConversationMerger

    init(
        rollupUpdater: ConversationRollupUpdater = ConversationRollupUpdater(),
        merger: ConversationMerger = ConversationMerger()
    ) {
        self.rollupUpdater = rollupUpdater
        self.merger = merger
    }

    // MARK: - Conversation Creation

    /// Finds an ACTIVE (non-archived) conversation for the given participants, or creates a new one.
    ///
    /// Archive-aware lookup:
    /// 1. Look for conversations with matching participantHash WHERE archivedAt IS NULL
    /// 2. If found, return the existing active conversation
    /// 3. If not found (all archived or none exist), create a NEW conversation
    ///
    /// Note: This method is serialized per participantHash to prevent duplicate conversations.
    func findOrCreateConversation(
        for identity: ConversationIdentity,
        in context: NSManagedObjectContext
    ) async throws -> Conversation {
        try await ConversationCreationSerializer.shared.findOrCreateConversation(for: identity, in: context)
    }

    /// Delegates to PersonFactory for consistent person creation.
    func findOrCreatePerson(
        email: String,
        displayName: String?,
        in context: NSManagedObjectContext
    ) -> Person {
        PersonFactory.findOrCreate(email: email, displayName: displayName, in: context)
    }

    // MARK: - Rollup Updates (delegated to ConversationRollupUpdater)

    /// Updates rollup data for a conversation. Must be called from within the conversation's context queue.
    func updateConversationRollups(for conversation: Conversation, myEmail: String) {
        rollupUpdater.updateRollups(for: conversation, myEmail: myEmail)
    }

    /// Updates rollups for ALL conversations - expensive O(n*m) operation.
    @MainActor
    func updateAllConversationRollups(in context: NSManagedObjectContext) async {
        await rollupUpdater.updateAllRollups(in: context)
    }

    /// Updates rollups only for conversations that were modified.
    @MainActor
    func updateRollupsForModifiedConversations(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {
        await rollupUpdater.updateRollupsForModified(conversationIDs: conversationIDs, in: context)
    }

    /// Updates rollups for conversations by keyHash.
    @MainActor
    func updateRollupsForConversations(
        keyHashes: Set<String>,
        in context: NSManagedObjectContext
    ) async {
        await rollupUpdater.updateRollupsForConversations(keyHashes: keyHashes, in: context)
    }

    // MARK: - Duplicate Management (delegated to ConversationMerger)

    /// Removes duplicate conversations by keyHash.
    func removeDuplicateConversations(in context: NSManagedObjectContext) async {
        await merger.removeDuplicateConversations(in: context)
    }

    /// Selects the winner conversation from a group of duplicates.
    func selectWinnerConversation(from group: [Conversation]) -> Conversation {
        merger.selectWinner(from: group)
    }

    /// Merges messages and data from loser into winner.
    func mergeConversation(from loser: Conversation, into winner: Conversation) {
        merger.merge(from: loser, into: winner)
    }

    /// Merges duplicate ACTIVE conversations with same participantHash.
    func mergeActiveConversationDuplicates(in context: NSManagedObjectContext) async {
        await merger.mergeActiveConversationDuplicates(in: context)
    }

    // MARK: - Conversation Identity

    /// Creates a conversation identity using Gmail threadId as the primary key.
    func createConversationIdentity(
        from headers: ProcessedHeaders,
        gmThreadId: String,
        myAliases: Set<String>
    ) -> ConversationIdentity {
        let messageHeaders = createMessageHeaders(from: headers)
        return makeConversationIdentity(from: messageHeaders, gmThreadId: gmThreadId, myAliases: myAliases)
    }

    /// Legacy function for backward compatibility.
    /// @deprecated Use createConversationIdentity(from:gmThreadId:myAliases:) instead
    func createConversationIdentity(
        from headers: ProcessedHeaders,
        myAliases: Set<String>
    ) -> ConversationIdentity {
        createConversationIdentity(from: headers, gmThreadId: "", myAliases: myAliases)
    }

    // MARK: - Private Helpers

    private func createMessageHeaders(from headers: ProcessedHeaders) -> [MessageHeader] {
        var messageHeaders: [MessageHeader] = []

        if let from = headers.from {
            messageHeaders.append(MessageHeader(name: "From", value: from))
        }

        for recipient in headers.to {
            let value = recipient.displayName != nil ? "\(recipient.displayName!) <\(recipient.email)>" : recipient.email
            messageHeaders.append(MessageHeader(name: "To", value: value))
        }

        for recipient in headers.cc {
            let value = recipient.displayName != nil ? "\(recipient.displayName!) <\(recipient.email)>" : recipient.email
            messageHeaders.append(MessageHeader(name: "Cc", value: value))
        }

        // Note: BCC is intentionally excluded from headers for identity creation

        if let listId = headers.listId {
            messageHeaders.append(MessageHeader(name: "List-Id", value: listId))
        }

        return messageHeaders
    }
}
