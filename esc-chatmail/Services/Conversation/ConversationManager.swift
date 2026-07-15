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
    private let findOrCreateConversationHandler: @Sendable (
        ConversationIdentity,
        Date?,
        String?,
        ConversationInboxSeed?,
        Bool,
        NSManagedObjectContext
    ) async throws -> NSManagedObjectID
    private let currentUserEmail: @MainActor @Sendable () -> String

    init(
        rollupUpdater: ConversationRollupUpdater = ConversationRollupUpdater(),
        merger: ConversationMerger = ConversationMerger(),
        findOrCreateConversationHandler: @escaping @Sendable (
            ConversationIdentity,
            Date?,
            String?,
            ConversationInboxSeed?,
            Bool,
            NSManagedObjectContext
        ) async throws -> NSManagedObjectID = { identity, initialLastMessageDate, initialSnippet, initialInboxSeed, reactivateArchivedIfNeeded, context in
            try await ConversationCreationSerializer.shared.findOrCreateConversationObjectID(
                for: identity,
                initialLastMessageDate: initialLastMessageDate,
                initialSnippet: initialSnippet,
                initialInboxSeed: initialInboxSeed,
                reactivateArchivedIfNeeded: reactivateArchivedIfNeeded,
                in: context
            )
        },
        currentUserEmail: @escaping @MainActor @Sendable () -> String = {
            AuthSession.shared.userEmail ?? ""
        }
    ) {
        self.rollupUpdater = rollupUpdater
        self.merger = merger
        self.findOrCreateConversationHandler = findOrCreateConversationHandler
        self.currentUserEmail = currentUserEmail
    }

    // MARK: - Conversation Creation

    /// Finds a conversation for the given participants, or creates a new one.
    ///
    /// Archive-aware lookup is owned by `ConversationRoutingPolicy`: active
    /// conversations are always eligible, while archived conversations are only
    /// reused when the caller's message should reactivate them.
    ///
    /// Note: This method is serialized per participantHash to prevent duplicate conversations.
    /// - Parameters:
    ///   - identity: The conversation identity containing participants and type
    ///   - initialLastMessageDate: Optional date to set as lastMessageDate when creating a new conversation (prevents UI flash where conversation appears at bottom before moving to top)
    ///   - initialSnippet: Optional row preview to seed when creating a new conversation (prevents a "No messages" flash until the message and its rollup persist)
    ///   - initialInboxSeed: Optional inbox indicators to seed when creating a new conversation (prevents the published row from missing its unread dot until the first rollup save)
    ///   - context: The Core Data context to use
    func findOrCreateConversationObjectID(
        for identity: ConversationIdentity,
        initialLastMessageDate: Date? = nil,
        initialSnippet: String? = nil,
        initialInboxSeed: ConversationInboxSeed? = nil,
        reactivateArchivedIfNeeded: Bool = true,
        in context: NSManagedObjectContext
    ) async throws -> NSManagedObjectID {
        try await findOrCreateConversationHandler(
            identity,
            initialLastMessageDate,
            initialSnippet,
            initialInboxSeed,
            reactivateArchivedIfNeeded,
            context
        )
    }

    /// Delegates to PersonFactory for consistent person creation.
    /// - Throws: CoreDataError.entityCreationFailed if entity creation fails
    func findOrCreatePerson(
        email: String,
        displayName: String?,
        in context: NSManagedObjectContext
    ) throws -> Person {
        try PersonFactory.findOrCreate(email: email, displayName: displayName, in: context)
    }

    // MARK: - Rollup Updates (delegated to ConversationRollupUpdater)

    /// Updates rollup data for a conversation. Must be called from within the conversation's context queue.
    func updateConversationRollups(for conversation: Conversation, myEmail: String) {
        rollupUpdater.updateRollups(for: conversation, myEmail: myEmail)
    }

    /// Refreshes stored conversation display names without touching sync-owned rollup fields.
    @MainActor
    func updateAllConversationDisplayNames(in context: NSManagedObjectContext) async {
        await rollupUpdater.updateDisplayNamesForAllConversations(
            in: context,
            myEmail: currentUserEmail()
        )
    }

    /// Refreshes stored display names for selected conversations without touching rollup fields.
    @MainActor
    func updateConversationDisplayNames(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {
        await rollupUpdater.updateDisplayNamesForConversations(
            conversationIDs: conversationIDs,
            in: context,
            myEmail: currentUserEmail()
        )
    }

    /// Updates rollups for ALL conversations - expensive O(n*m) operation.
    @MainActor
    func updateAllConversationRollups(in context: NSManagedObjectContext) async {
        await rollupUpdater.updateAllRollups(
            in: context,
            myEmail: currentUserEmail()
        )
    }

    /// Updates rollups only for conversations that were modified.
    @MainActor
    func updateRollupsForModifiedConversations(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {
        await rollupUpdater.updateRollupsForModified(
            conversationIDs: conversationIDs,
            in: context,
            myEmail: currentUserEmail()
        )
    }

    /// Updates rollups for conversations by keyHash.
    @MainActor
    func updateRollupsForConversations(
        keyHashes: Set<String>,
        in context: NSManagedObjectContext
    ) async {
        await rollupUpdater.updateRollupsForConversations(
            keyHashes: keyHashes,
            in: context,
            myEmail: currentUserEmail()
        )
    }

    /// Repairs active conversations that have a date but no preview text.
    @MainActor
    func repairMissingConversationPreviews(in context: NSManagedObjectContext) async -> ConversationPreviewRepairResult {
        await rollupUpdater.repairMissingConversationPreviews(in: context)
    }

    /// Archives stranded conversation shells that have a date but no messages,
    /// leaving alone anything created or active within the grace period.
    @MainActor
    func archiveMessagelessConversations(in context: NSManagedObjectContext) async -> Int {
        await rollupUpdater.archiveMessagelessConversations(
            in: context,
            olderThan: Date(timeIntervalSinceNow: -ConversationRollupUpdater.messagelessConversationGracePeriod)
        )
    }

    // MARK: - Duplicate Management (delegated to ConversationMerger)

    /// Removes duplicate conversations by keyHash.
    func removeDuplicateConversations(in context: NSManagedObjectContext) async {
        await merger.removeDuplicateConversations(in: context)
    }

    /// Selects the winner conversation from a group of duplicates.
    /// Returns nil if group is empty (logs error instead of crashing).
    func selectWinnerConversation(from group: [Conversation]) -> Conversation? {
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

    /// Creates a participant-set conversation identity from message headers
    /// (From+To+Cc minus the user's aliases).
    func createConversationIdentity(
        from headers: ProcessedHeaders,
        myAliases: Set<String>
    ) -> ConversationIdentity {
        let messageHeaders = createMessageHeaders(from: headers)
        return makeConversationIdentity(from: messageHeaders, myAliases: myAliases)
    }

    // MARK: - Private Helpers

    private func createMessageHeaders(from headers: ProcessedHeaders) -> [MessageHeader] {
        var messageHeaders: [MessageHeader] = []

        if let from = headers.from {
            messageHeaders.append(MessageHeader(name: "From", value: from))
        }

        for recipient in headers.to {
            let value = recipient.displayName.map { "\($0) <\(recipient.email)>" } ?? recipient.email
            messageHeaders.append(MessageHeader(name: "To", value: value))
        }

        for recipient in headers.cc {
            let value = recipient.displayName.map { "\($0) <\(recipient.email)>" } ?? recipient.email
            messageHeaders.append(MessageHeader(name: "Cc", value: value))
        }

        // Note: BCC is intentionally excluded from headers for identity creation

        if let listId = headers.listId {
            messageHeaders.append(MessageHeader(name: "List-Id", value: listId))
        }

        return messageHeaders
    }
}
