import Foundation
import CoreData

protocol MessageActionsCoreDataStacking: AnyObject {
    var viewContext: NSManagedObjectContext { get }
    func newBackgroundContext() -> NSManagedObjectContext
    @discardableResult
    func saveIfNeeded(context: NSManagedObjectContext, caller: String) -> Bool
}

extension MessageActionsCoreDataStacking {
    @discardableResult
    func saveIfNeeded(context: NSManagedObjectContext) -> Bool {
        saveIfNeeded(context: context, caller: #function)
    }
}

extension CoreDataStack: MessageActionsCoreDataStacking {}

@MainActor
final class MessageActions: ObservableObject {
    typealias UnreadInboxMessageCounter = @Sendable (NSManagedObjectContext, Conversation) throws -> Int

    private let coreDataStack: any MessageActionsCoreDataStacking
    private let pendingActionsManager: any PendingActionsManagerProtocol
    private let unreadInboxMessageCounter: UnreadInboxMessageCounter
    private let rollupMutationSerializer: ConversationRollupMutationSerializer
    private let syncRunCoordinator: SyncRunCoordinator

    init(
        coreDataStack: any MessageActionsCoreDataStacking,
        pendingActionsManager: any PendingActionsManagerProtocol,
        rollupMutationSerializer: ConversationRollupMutationSerializer = .shared,
        syncRunCoordinator: SyncRunCoordinator = .shared
    ) {
        self.coreDataStack = coreDataStack
        self.pendingActionsManager = pendingActionsManager
        self.rollupMutationSerializer = rollupMutationSerializer
        self.syncRunCoordinator = syncRunCoordinator
        self.unreadInboxMessageCounter = { context, conversation in
            try Self.countUnreadInboxMessages(in: context, conversation: conversation)
        }
    }

    init(
        coreDataStack: any MessageActionsCoreDataStacking,
        pendingActionsManager: any PendingActionsManagerProtocol,
        unreadInboxMessageCounter: @escaping UnreadInboxMessageCounter,
        rollupMutationSerializer: ConversationRollupMutationSerializer = .shared,
        syncRunCoordinator: SyncRunCoordinator = .shared
    ) {
        self.coreDataStack = coreDataStack
        self.pendingActionsManager = pendingActionsManager
        self.unreadInboxMessageCounter = unreadInboxMessageCounter
        self.rollupMutationSerializer = rollupMutationSerializer
        self.syncRunCoordinator = syncRunCoordinator
    }

    /// Takes a non-exclusive account-work lease before any optimistic mutation
    /// can suspend or save, then holds it through durable pending-action
    /// enqueue. The lease does not wait for an in-progress sync run, so a user
    /// action never queues behind initial sync, but an account transition still
    /// cannot interleave: the lease is refused once teardown starts, and
    /// teardown waits for an outstanding lease before replacing the store.
    ///
    /// Because nothing on this path parks on the exclusive boundary any more,
    /// a cancelled caller task (`ViewModelTaskManager` same-key cancel, or
    /// `cancelAll()` on disappear) can no longer discard the user's action.
    private func performAccountWork(
        _ operation: (SyncRun) async -> Void
    ) async {
        guard let request = await syncRunCoordinator.makeAccountWorkRequest(),
              let syncRun = await syncRunCoordinator.acquireAccountWorkLease(
                  kind: .pendingActions,
                  for: request
              ) else {
            return
        }

        await operation(syncRun)
        await syncRunCoordinator.endRun(syncRun)
    }

    // MARK: - Mark Read/Unread

    func markAsRead(message: Message) async {
        await performAccountWork { syncRun in
            await self.updateReadState(
                messageID: message.objectID,
                conversationID: message.conversation?.objectID,
                isUnread: false,
                actionType: .markRead,
                within: syncRun
            )
        }
    }

    func markAsUnread(message: Message) async {
        await performAccountWork { syncRun in
            await self.updateReadState(
                messageID: message.objectID,
                conversationID: message.conversation?.objectID,
                isUnread: true,
                actionType: .markUnread,
                within: syncRun
            )
        }
    }

    func markConversationAsUnread(conversation: Conversation) async {
        await performAccountWork { syncRun in
            let conversationID = conversation.objectID
            let conversationKey = conversationID.uriRepresentation().absoluteString
            await self.rollupMutationSerializer.perform(conversationKeys: [conversationKey]) { [weak self] in
                guard let self,
                      let messageId = await self.performMarkConversationAsUnread(
                        conversationID: conversationID
                      ) else {
                    return
                }
                await self.queueReadStateAction(
                    type: .markUnread,
                    messageId: messageId,
                    within: syncRun
                )
            }
        }
    }

    func markConversationAsRead(conversation: Conversation) async {
        await performAccountWork { syncRun in
            let conversationID = conversation.objectID
            let unreadInboxMessageIDs = await self.snapshotUnreadInboxMessageObjectIDs(
                conversationID: conversationID
            )
            guard !unreadInboxMessageIDs.isEmpty else { return }

            let conversationKey = conversationID.uriRepresentation().absoluteString
            await self.rollupMutationSerializer.perform(conversationKeys: [conversationKey]) { [weak self] in
                await self?.performMarkMessagesAsReadBatch(
                    messageIDs: unreadInboxMessageIDs,
                    conversationID: conversationID,
                    within: syncRun
                )
            }
        }
    }

    /// Snapshots the unread message IDs that should be cleared when a chat opens.
    /// Marking exactly these IDs, and not "whatever is unread" at the time
    /// the mark runs, is what keeps a later arrival unread.
    ///
    /// The fetch runs on a background context and reads the store only: it
    /// used to run on the main-queue view context at every chat open, driven
    /// by an index over every unread message in the mailbox
    /// (`docs/scalability-review.md`, `chat-open-unread-snapshot`).
    /// `MessagePredicates.unreadInInbox` says how the predicate avoids that
    /// index. An unsaved conversation has no stored messages to snapshot.
    func snapshotUnreadInboxMessageObjectIDs(
        conversationID: NSManagedObjectID
    ) async -> [NSManagedObjectID] {
        await startUnreadInboxSnapshot(conversationID: conversationID).value
    }

    /// Starts the snapshot's fetch before returning, so the caller can start
    /// it in the turn a chat opens and await the IDs in a task of its own.
    ///
    /// The fetch runs in a detached task, which needs nothing from the main
    /// actor: it goes to the background context's queue from the global
    /// executor. When the whole snapshot was awaited through this
    /// main-actor class it could not start until the main actor was free
    /// again, which at chat open is after the transcript's first layout, and
    /// a message saved meanwhile was in the snapshot and was marked read
    /// with the rest. A plain `Task` here inherits the main actor and waits
    /// for it in the same way. What is left between the open and the fetch
    /// is the hop to that task and the hop to the context's queue.
    func startUnreadInboxSnapshot(conversationID: NSManagedObjectID) -> Task<[NSManagedObjectID], Never> {
        guard !conversationID.isTemporaryID else { return Task.detached { [] } }

        let context = coreDataStack.newBackgroundContext()
        return Task.detached(priority: .userInitiated) {
            await context.perform {
                let request = NSFetchRequest<NSManagedObjectID>(entityName: "Message")
                request.predicate = MessagePredicates.unreadInInbox(conversationObjectID: conversationID)
                request.fetchBatchSize = 50
                request.includesPendingChanges = false
                request.resultType = .managedObjectIDResultType

                do {
                    return try context.fetch(request)
                } catch {
                    Log.error(
                        "Failed to snapshot unread INBOX message IDs for conversation",
                        category: .coreData,
                        error: error
                    )
                    return []
                }
            }
        }
    }

    /// Filters an exact insertion set down to unread INBOX messages.
    /// This prevents a later arrival from consuming unrelated unread mail.
    func snapshotUnreadInboxMessageObjectIDs(
        messageObjectIDs: [NSManagedObjectID]
    ) -> [NSManagedObjectID] {
        guard !messageObjectIDs.isEmpty else { return [] }

        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Message")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "SELF IN %@", messageObjectIDs),
            NSPredicate(format: "isUnread == YES"),
            NSPredicate(format: "ANY labels.id == %@", "INBOX")
        ])
        request.fetchBatchSize = messageObjectIDs.count
        request.includesPendingChanges = false
        request.resultType = .managedObjectIDResultType

        return (try? coreDataStack.viewContext.fetch(request)) ?? []
    }

    private func updateReadState(
        messageID: NSManagedObjectID,
        conversationID: NSManagedObjectID?,
        isUnread: Bool,
        actionType: PendingAction.ActionType,
        within syncRun: SyncRun
    ) async {
        guard let conversationID else { return }
        let conversationKey = conversationID.uriRepresentation().absoluteString
        await rollupMutationSerializer.perform(conversationKeys: [conversationKey]) { [weak self] in
            guard let self,
                  let messageId = await self.performReadStateMutation(
                    messageID: messageID,
                    conversationID: conversationID,
                    isUnread: isUnread,
                    actionType: actionType
                  ) else {
                return
            }
            await self.queueReadStateAction(
                type: actionType,
                messageId: messageId,
                within: syncRun
            )
        }
    }

    private func performReadStateMutation(
        messageID: NSManagedObjectID,
        conversationID: NSManagedObjectID,
        isUnread: Bool,
        actionType: PendingAction.ActionType
    ) async -> String? {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            context.refreshAllObjects()
            guard let message = try? context.existingObject(with: messageID) as? Message,
                  let conversation = try? context.existingObject(with: conversationID) as? Conversation,
                  message.conversation?.objectID == conversation.objectID,
                  message.isUnread != isUnread else {
                return nil
            }

            message.isUnread = isUnread
            message.localModifiedAt = Date()
            guard Self.applyInboxRollup(to: conversation, overlaying: [message], in: context),
                  context.saveOrLog(operation: "mark message as \(actionType.rawValue)") else {
                context.rollback()
                return nil
            }

            return message.id
        }
    }

    private func performMarkConversationAsUnread(
        conversationID: NSManagedObjectID
    ) async -> String? {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            context.refreshAllObjects()
            guard let conversation = try? context.existingObject(with: conversationID) as? Conversation,
                  let latestInboxMessage = try? Self.fetchLatestStoredInboxMessage(
                      of: conversation,
                      excluding: [],
                      in: context
                  ),
                  !latestInboxMessage.isUnread else {
                return nil
            }

            latestInboxMessage.isUnread = true
            latestInboxMessage.localModifiedAt = Date()
            guard Self.applyInboxRollup(to: conversation, overlaying: [latestInboxMessage], in: context),
                  context.saveOrLog(operation: "mark conversation as unread") else {
                context.rollback()
                return nil
            }

            return latestInboxMessage.id
        }
    }

    /// Mark message as read using ObjectID - safe to call from background threads
    func markAsRead(messageID: NSManagedObjectID) async {
        await performAccountWork { syncRun in
            let context = self.coreDataStack.newBackgroundContext()
            let conversationID: NSManagedObjectID? = await context.perform {
                context.refreshAllObjects()
                guard let message = try? context.existingObject(with: messageID) as? Message else {
                    return nil
                }
                return message.conversation?.objectID
            }

            guard let conversationID else { return }
            let conversationKey = conversationID.uriRepresentation().absoluteString
            await self.rollupMutationSerializer.perform(conversationKeys: [conversationKey]) { [weak self] in
                guard let self,
                      let gmailMessageId = await self.performReadStateMutation(
                        messageID: messageID,
                        conversationID: conversationID,
                        isUnread: false,
                        actionType: .markRead
                      ) else {
                    return
                }
                await self.queueReadStateAction(
                    type: .markRead,
                    messageId: gmailMessageId,
                    within: syncRun
                )
            }
        }
    }

    /// Batch mark messages as read - prevents race condition with new messages
    /// Uses a single transaction to ensure atomic update of conversation unread count
    func markMessagesAsReadBatch(messageIDs: [NSManagedObjectID], conversationID: NSManagedObjectID) async {
        await performAccountWork { syncRun in
            let conversationKey = conversationID.uriRepresentation().absoluteString
            await self.rollupMutationSerializer.perform(conversationKeys: [conversationKey]) { [weak self] in
                await self?.performMarkMessagesAsReadBatch(
                    messageIDs: messageIDs,
                    conversationID: conversationID,
                    within: syncRun
                )
            }
        }
    }

    private func performMarkMessagesAsReadBatch(
        messageIDs: [NSManagedObjectID],
        conversationID: NSManagedObjectID,
        within syncRun: SyncRun
    ) async {
        let context = coreDataStack.newBackgroundContext()
        let unreadInboxMessageCounter = self.unreadInboxMessageCounter

        let batchResult: (messageIds: [String], sourceConversationId: UUID?) = await context.perform {
            var markedIds: [String] = []
            let modificationDate = Date()
            var sourceConversationId: UUID?

            let messagesByID = Self.fetchMessagesWithLabels(messageIDs, in: context)
            for messageID in messageIDs {
                guard let message = messagesByID[messageID] else { continue }
                guard message.isUnread,
                      message.conversation?.objectID == conversationID,
                      message.labels?.contains(where: { $0.id == "INBOX" }) == true else {
                    continue
                }

                message.isUnread = false
                message.localModifiedAt = modificationDate
                sourceConversationId = sourceConversationId ?? message.conversation?.id

                if !message.id.isEmpty {
                    markedIds.append(message.id)
                }
            }

            guard let conversation = try? context.existingObject(with: conversationID) as? Conversation else {
                context.rollback()
                return ([], sourceConversationId)
            }
            sourceConversationId = sourceConversationId ?? conversation.id

            do {
                conversation.inboxUnreadCount = Int32(
                    try unreadInboxMessageCounter(context, conversation)
                )
            } catch {
                context.rollback()
                Log.error(
                    "Aborting batch mark as read because the unread INBOX count failed",
                    category: .coreData,
                    error: error
                )
                return ([], sourceConversationId)
            }

            // Don't sync to Gmail if the local batch update didn't persist.
            guard context.saveOrLog(operation: "batch mark messages as read") else {
                return ([], sourceConversationId)
            }
            return (markedIds, sourceConversationId)
        }

        guard !batchResult.messageIds.isEmpty else { return }

        if let sourceConversationId = batchResult.sourceConversationId {
            await pendingActionsManager.queueConversationAction(
                type: .markRead,
                sourceConversationId: sourceConversationId,
                messageIds: batchResult.messageIds,
                within: syncRun
            )
        } else {
            for messageId in batchResult.messageIds {
                await pendingActionsManager.queueAction(
                    type: .markRead,
                    messageId: messageId,
                    payload: nil,
                    within: syncRun
                )
            }
        }
    }

    private func queueReadStateAction(
        type: PendingAction.ActionType,
        messageId: String,
        within syncRun: SyncRun
    ) async {
        guard !messageId.isEmpty else { return }
        await pendingActionsManager.queueAction(
            type: type,
            messageId: messageId,
            payload: nil,
            within: syncRun
        )
    }

    // MARK: - Archive

    /// Archive, Report Spam and star all change labels, and they do it on a
    /// background context inside the conversation's rollup serializer block,
    /// as the read-state actions above do. They used to run on the
    /// main-queue view context: a conversation-wide action walked every
    /// message the conversation ever held there, two round trips a message,
    /// and any label change loaded every member of that label into the view
    /// context, where they stayed (`docs/scalability-review.md`,
    /// `archive-spam-star-main-thread-viewcontext`). The background context
    /// is dropped when the action returns, and the view context learns of
    /// the change from the save, as it does for a sync.
    func archive(message: Message) async {
        await performAccountWork { syncRun in
            guard let messageID = self.storedObjectIDs(of: [message], operation: "archive")?.first else {
                return
            }
            let conversationKeys = Self.conversationKeys(for: [message.conversation?.objectID])
            await self.rollupMutationSerializer.perform(conversationKeys: conversationKeys) { [weak self] in
                guard let self,
                      let gmailMessageId = await self.performArchive(messageID: messageID) else {
                    return
                }
                // Queue sync to Gmail (remove INBOX label)
                await self.queueReadStateAction(
                    type: .archive,
                    messageId: gmailMessageId,
                    within: syncRun
                )
            }
        }
    }

    /// Removes INBOX from one message and recomputes its conversation's
    /// rollup in the same save. Returns the message's Gmail ID, or nil when
    /// nothing was saved (the message is gone, is not in the inbox, or a
    /// read or the save failed).
    private func performArchive(messageID: NSManagedObjectID) async -> String? {
        let save = makeBackgroundSave()
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            guard let message = try? context.existingObject(with: messageID) as? Message,
                  let inboxLabel = message.labels?.first(where: { $0.id == "INBOX" }) else {
                return nil
            }

            // Update local state and mark as locally modified for conflict detection
            message.removeFromLabels(inboxLabel)
            message.localModifiedAt = Date()
            if let conversation = message.conversation,
               !Self.applyInboxRollup(to: conversation, overlaying: [message], in: context) {
                context.rollback()
                return nil
            }
            guard save(context, "archive message") else {
                Log.error("Not queuing archive: local save failed", category: .message)
                context.rollback()
                return nil
            }
            return message.id
        }
    }

    func archiveConversation(conversation: Conversation) async {
        await performConversationWideMutation(
            ConversationWideMutation(kind: .archive, isBatch: false),
            on: [conversation]
        )
    }

    /// Archives multiple conversations in a single batch operation.
    /// - Parameter conversations: The conversations to archive
    /// - Note: Performs a single Core Data save and queues a single pending action.
    func archiveConversations(conversations: [Conversation]) async {
        await performConversationWideMutation(
            ConversationWideMutation(kind: .archive, isBatch: true),
            on: conversations
        )
    }

    /// Reports multiple conversations as spam in a single batch operation.
    /// - Parameter conversations: The conversations to report as spam
    /// - Note: Performs a single Core Data save and queues a single pending action.
    func reportSpamConversations(conversations: [Conversation]) async {
        await performConversationWideMutation(
            ConversationWideMutation(kind: .reportSpam, isBatch: true),
            on: conversations
        )
    }

    /// Reports a conversation as spam by adding the SPAM label to all messages.
    /// Also archives the conversation locally to remove it from the chat list.
    /// - Parameter conversation: The conversation to report as spam
    func reportSpamConversation(conversation: Conversation) async {
        await performConversationWideMutation(
            ConversationWideMutation(kind: .reportSpam, isBatch: false),
            on: [conversation]
        )
    }

    /// One of the four conversation-wide actions. The single-conversation and
    /// batch entry points differ in two ways that predate this type and are
    /// kept: see `isBatch`.
    private struct ConversationWideMutation: Sendable {
        enum Kind: Sendable {
            case archive
            case reportSpam
        }

        let kind: Kind
        /// A batch archives a conversation that has no messages (its rollup
        /// is all there is to change), and a batch archive does nothing at
        /// all when the store has no INBOX label. The single-conversation
        /// actions leave an empty conversation alone, and a single archive
        /// without an INBOX label still marks the conversation archived.
        let isBatch: Bool

        var pendingActionType: PendingAction.ActionType {
            switch kind {
            case .archive: return .archiveConversation
            case .reportSpam: return .reportSpam
            }
        }

        var operation: String {
            switch (kind, isBatch) {
            case (.archive, false): return "archive conversation"
            case (.archive, true): return "batch archive conversations"
            case (.reportSpam, false): return "report conversation as spam"
            case (.reportSpam, true): return "batch report conversations as spam"
            }
        }
    }

    private func performConversationWideMutation(
        _ mutation: ConversationWideMutation,
        on conversations: [Conversation]
    ) async {
        await performAccountWork { syncRun in
            // The pending action names the first conversation, as it always has.
            guard let sourceConversationId = conversations.first?.id,
                  let conversationIDs = self.storedObjectIDs(of: conversations, operation: mutation.operation) else {
                return
            }

            // The conversations' turns only, never the cleanup-sensitive
            // gate: the gate is every send's, draft save's and cleanup
            // pass's, and an action that held it kept all of them waiting
            // for as long as it ran, and itself waited for a whole cleanup.
            // A send to one of these conversations takes that conversation's
            // turn inside the gate, so it runs wholly before this or wholly
            // after it, and reads the store's archive state when it does
            // (`GmailSendService.createOptimisticMessage`). A holder of a
            // conversation's turn must never ask for the gate: see
            // `ConversationRollupMutationSerializer.performThrowingAnchoredSendMutation(conversationIDs:onEnqueued:operation:)`.
            let conversationKeys = Self.conversationKeys(for: conversationIDs)
            await self.rollupMutationSerializer.perform(conversationKeys: conversationKeys) { [weak self] in
                guard let self else { return }
                guard let outcome = await self.saveConversationWideMutation(
                    mutation,
                    to: conversationIDs
                ) else {
                    Log.error("Not queuing \(mutation.operation): nothing was saved", category: .message)
                    return
                }
                guard outcome.changedConversationCount > 0 else {
                    Log.info("Nothing to \(mutation.operation): no conversation still needed it", category: .message)
                    return
                }
                Log.info(
                    "Did \(mutation.operation): \(outcome.changedConversationCount) conversations, \(outcome.messageIds.count) messages",
                    category: .message
                )

                // Queue sync to Gmail
                guard !outcome.messageIds.isEmpty else { return }
                await self.pendingActionsManager.queueConversationAction(
                    type: mutation.pendingActionType,
                    sourceConversationId: sourceConversationId,
                    messageIds: outcome.messageIds,
                    within: syncRun
                )
            }
        }
    }

    /// What a conversation-wide action saved.
    private struct ConversationWideOutcome: Sendable {
        /// The Gmail IDs the pending action should name.
        var messageIds: [String] = []
        /// How many conversations the action changed. One the store already
        /// had it applied to is not counted.
        var changedConversationCount = 0
    }

    private func saveConversationWideMutation(
        _ mutation: ConversationWideMutation,
        to conversationIDs: [NSManagedObjectID]
    ) async -> ConversationWideOutcome? {
        let save = makeBackgroundSave()
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            Self.applyConversationWideMutation(
                mutation,
                to: conversationIDs,
                in: context,
                savingWith: save
            )
        }
    }

    /// Applies a conversation-wide action and saves it, all in one save.
    /// Returns what was saved, or nil when a read or the save failed or the
    /// action does not apply. Call inside `context.perform`.
    ///
    /// Every message of each conversation is stamped `localModifiedAt`, and
    /// Report Spam adds SPAM to every one. INBOX is removed only where it is
    /// set: removing a label a message does not carry changed nothing. A
    /// conversation the store already has the action applied to is left as
    /// it is (`isAlreadyApplied`).
    nonisolated private static func applyConversationWideMutation(
        _ mutation: ConversationWideMutation,
        to conversationIDs: [NSManagedObjectID],
        in context: NSManagedObjectContext,
        savingWith save: BackgroundSave
    ) -> ConversationWideOutcome? {
        let inboxLabel: Label?
        let spamLabel: Label?
        do {
            inboxLabel = try fetchLabel(id: "INBOX", in: context)
            spamLabel = mutation.kind == .reportSpam ? try fetchLabel(id: "SPAM", in: context) : nil
        } catch {
            // A label that could not be read is not a label the store
            // lacks. Taken for one, a single archive marked the conversation
            // archived and left every message in the inbox.
            Log.error("Failed to read a label to \(mutation.operation)", category: .coreData, error: error)
            return nil
        }
        if mutation.kind == .archive, mutation.isBatch, inboxLabel == nil {
            Log.warning("INBOX label not found, cannot archive", category: .message)
            return nil
        }

        var outcome = ConversationWideOutcome()
        let modificationDate = Date()

        for conversationID in conversationIDs {
            guard let conversation = try? context.existingObject(with: conversationID) as? Conversation else {
                continue
            }
            if isAlreadyApplied(mutation.kind, to: conversation, spamLabel: spamLabel, in: context) {
                continue
            }

            let messages: [Message]
            do {
                messages = try fetchMessagesWithLabels(of: conversation, in: context)
            } catch {
                // A failed read is not an empty conversation: archiving it
                // on that say-so would leave its messages in the inbox.
                Log.error("Failed to load messages to \(mutation.operation)", category: .coreData, error: error)
                context.rollback()
                return nil
            }
            if !mutation.isBatch, messages.isEmpty {
                Log.warning("No messages to \(mutation.operation)", category: .message)
                return nil
            }

            switch mutation.kind {
            case .archive:
                // Without an INBOX label there is nothing to remove, and the
                // messages are left unstamped, as they were before this ran
                // on a background context.
                guard let inboxLabel else { break }
                for message in messages {
                    if message.labels?.contains(inboxLabel) == true {
                        message.removeFromLabels(inboxLabel)
                    }
                    message.localModifiedAt = modificationDate
                    if let gmailMessageID = gmailMessageIDForConversationAction(message) {
                        outcome.messageIds.append(gmailMessageID)
                    }
                }
            case .reportSpam:
                for message in messages {
                    if let inboxLabel, message.labels?.contains(inboxLabel) == true {
                        message.removeFromLabels(inboxLabel)
                    }
                    if let spamLabel {
                        message.addToLabels(spamLabel)
                    }
                    message.localModifiedAt = modificationDate
                    if let gmailMessageID = gmailMessageIDForConversationAction(message) {
                        outcome.messageIds.append(gmailMessageID)
                    }
                }
            }

            // CRITICAL: archivedAt marks this conversation as archived, so
            // that future emails from these participants create a NEW
            // conversation. The rollup fields go with it, in the same save,
            // to prevent un-archiving.
            applyArchivedConversationRollup(to: conversation, at: modificationDate)
            outcome.changedConversationCount += 1
        }

        guard outcome.changedConversationCount > 0 else { return outcome }
        guard save(context, mutation.operation) else {
            context.rollback()
            return nil
        }
        return outcome
    }

    /// Whether the store already has the action applied to `conversation`:
    /// it is archived with an empty inbox rollup, none of its messages
    /// carries INBOX, and for Report Spam every one carries SPAM. Call
    /// inside `context.perform`.
    ///
    /// The list row of an archived conversation stays until the archive's
    /// save reaches the view context, which for a long chat is seconds, and
    /// a second swipe in that time runs the action again behind the first.
    /// Run again it stamped every message a second time, moved `archivedAt`,
    /// and queued a second Gmail action for the same messages.
    ///
    /// A count that fails answers false: the action then runs, and its own
    /// reads decide whether anything is saved. Report Spam with no SPAM
    /// label in the store labels nothing, so the store cannot say whether it
    /// ran, and it runs again.
    nonisolated private static func isAlreadyApplied(
        _ kind: ConversationWideMutation.Kind,
        to conversation: Conversation,
        spamLabel: Label?,
        in context: NSManagedObjectContext
    ) -> Bool {
        guard conversation.archivedAt != nil,
              !conversation.hasInbox,
              conversation.inboxUnreadCount == 0,
              conversation.latestInboxDate == nil else {
            return false
        }
        do {
            let inInbox = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            inInbox.predicate = storedInboxPredicate(of: conversation, excluding: [], unreadOnly: false)
            guard try context.count(for: inInbox) == 0 else { return false }

            switch kind {
            case .archive:
                return true
            case .reportSpam:
                guard spamLabel != nil else { return false }
                let notSpam = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
                notSpam.predicate = NSPredicate(
                    format: "conversation == %@ AND SUBQUERY(labels, $label, $label.id == %@).@count == 0",
                    conversation,
                    "SPAM"
                )
                return try context.count(for: notSpam) == 0
            }
        } catch {
            Log.error("Failed to read whether a conversation is already archived", category: .coreData, error: error)
            return false
        }
    }

    // MARK: - Star/Unstar

    func star(message: Message) async {
        await updateStarState(message: message, isStarred: true, actionType: .star)
    }

    func unstar(message: Message) async {
        await updateStarState(message: message, isStarred: false, actionType: .unstar)
    }

    // MARK: - Helpers

    /// The stack's `saveIfNeeded`, for a block that runs on a background
    /// context's queue: the context to save and the caller's name.
    private typealias BackgroundSave = @Sendable (NSManagedObjectContext, String) -> Bool

    /// Makes the save a background `perform` block calls, so that the block
    /// captures this closure and not the stack.
    ///
    /// `nonisolated(unsafe)`: the stack is held as
    /// `any MessageActionsCoreDataStacking`, which is not `Sendable`, and a
    /// `perform` block that captures it bare is an error under Swift 6.2
    /// (CI's Xcode 26) and nothing under Swift 6.4 (this Mac's Xcode 27),
    /// which is how the first version of this path passed here and failed
    /// both CI builds. The one thing the closure does with the stack is call
    /// `saveIfNeeded`, which does all of its work inside the given context's
    /// own `performAndWait` and so may be called from any queue.
    private func makeBackgroundSave() -> BackgroundSave {
        nonisolated(unsafe) let coreDataStack = self.coreDataStack
        return { context, caller in
            coreDataStack.saveIfNeeded(context: context, caller: caller)
        }
    }

    /// The objectIDs of `objects`, as a background context can resolve them,
    /// or nil when it could not.
    ///
    /// An object the view context has not saved has a temporary ID that no
    /// other context can resolve (a newly composed chat, say). When these
    /// actions ran on the view context their own save wrote such a row, so
    /// the view context is saved first here in that case, and only then.
    private func storedObjectIDs(
        of objects: [NSManagedObject],
        operation: String
    ) -> [NSManagedObjectID]? {
        if objects.contains(where: { $0.objectID.isTemporaryID }) {
            guard coreDataStack.saveIfNeeded(context: coreDataStack.viewContext, caller: operation) else {
                Log.error("Not doing \(operation): the view context could not be saved first", category: .message)
                return nil
            }
        }
        let objectIDs = objects.map(\.objectID)
        guard !objectIDs.contains(where: \.isTemporaryID) else {
            Log.error("Not doing \(operation): an object has no stored row", category: .message)
            return nil
        }
        return objectIDs
    }

    nonisolated private static func conversationKeys(
        for conversationIDs: [NSManagedObjectID?]
    ) -> Set<String> {
        Set(conversationIDs.compactMap { $0?.uriRepresentation().absoluteString })
    }

    /// Recomputes `hasInbox`, `inboxUnreadCount` and `latestInboxDate` for a
    /// conversation whose only unsaved changes in `context` are to
    /// `changedMessages`. Returns false, changing nothing, when a read
    /// failed: a failed read is never "no INBOX messages". Call inside
    /// `context.perform`.
    ///
    /// The store answers for every other message with two counts and a
    /// one-row fetch, and the changed messages are added from memory. This
    /// used to fetch every INBOX message of the conversation as a full
    /// object, body text included, to count them: 17,585 rows and 165 MB for
    /// one tap in a 20,000-message list (`docs/scalability-review.md`,
    /// `single-archive-rollup-materializes-inbox`).
    ///
    /// The changed messages are left out of the store's answer by ID, not
    /// folded in by `includesPendingChanges`: a one-row "newest INBOX
    /// message" fetch that SQLite answers with the row just archived comes
    /// back empty once the unsaved change is applied to it, which reads as
    /// an inbox conversation with no latest date.
    nonisolated private static func applyInboxRollup(
        to conversation: Conversation,
        overlaying changedMessages: [Message],
        in context: NSManagedObjectContext
    ) -> Bool {
        do {
            let changedIDs = changedMessages.map(\.objectID)
            let storedInbox = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            storedInbox.predicate = storedInboxPredicate(
                of: conversation,
                excluding: changedIDs,
                unreadOnly: false
            )
            storedInbox.includesPendingChanges = false
            var inboxCount = try context.count(for: storedInbox)

            let storedUnread = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            storedUnread.predicate = storedInboxPredicate(
                of: conversation,
                excluding: changedIDs,
                unreadOnly: true
            )
            storedUnread.includesPendingChanges = false
            var unreadCount = try context.count(for: storedUnread)

            var latestDate = try fetchLatestStoredInboxMessage(
                of: conversation,
                excluding: changedIDs,
                in: context
            )?.internalDate

            for message in changedMessages where !message.isDeleted &&
                message.conversation == conversation &&
                message.labels?.contains(where: { $0.id == "INBOX" }) == true {
                inboxCount += 1
                if message.isUnread { unreadCount += 1 }
                latestDate = max(latestDate ?? message.internalDate, message.internalDate)
            }

            conversation.hasInbox = inboxCount > 0
            conversation.inboxUnreadCount = Int32(unreadCount)
            conversation.latestInboxDate = latestDate
            return true
        } catch {
            Log.error("Failed to read the INBOX rollup of a conversation", category: .coreData, error: error)
            return false
        }
    }

    /// The conversation's INBOX messages as the store has them, leaving out
    /// `excludedIDs`.
    nonisolated private static func storedInboxPredicate(
        of conversation: Conversation,
        excluding excludedIDs: [NSManagedObjectID],
        unreadOnly: Bool
    ) -> NSPredicate {
        var predicates = [
            unreadOnly
                ? MessagePredicates.unreadInInbox(conversationObjectID: conversation.objectID)
                : NSPredicate(format: "conversation == %@ AND ANY labels.id == %@", conversation, "INBOX")
        ]
        if !excludedIDs.isEmpty {
            predicates.append(NSPredicate(format: "NOT (SELF IN %@)", excludedIDs))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    /// The newest INBOX message of the conversation as the store has it,
    /// leaving out `excludedIDs`. One row, not the conversation's inbox.
    nonisolated private static func fetchLatestStoredInboxMessage(
        of conversation: Conversation,
        excluding excludedIDs: [NSManagedObjectID],
        in context: NSManagedObjectContext
    ) throws -> Message? {
        let request = Message.fetchRequest()
        request.predicate = storedInboxPredicate(of: conversation, excluding: excludedIDs, unreadOnly: false)
        request.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: false)]
        request.fetchLimit = 1
        request.includesPendingChanges = false
        return try context.fetch(request).first
    }

    /// Every message of a conversation with its labels loaded, for a
    /// conversation-wide action. Call inside `context.perform`.
    nonisolated private static func fetchMessagesWithLabels(
        of conversation: Conversation,
        in context: NSManagedObjectContext
    ) throws -> [Message] {
        let request = Message.fetchRequest()
        request.predicate = MessagePredicates.inConversation(conversation)
        request.relationshipKeyPathsForPrefetching = ["labels"]
        request.fetchBatchSize = markReadFetchChunkSize
        return try context.fetch(request)
    }

    nonisolated private static func countUnreadInboxMessages(
        in context: NSManagedObjectContext,
        conversation: Conversation
    ) throws -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
        request.predicate = MessagePredicates.unreadInInbox(conversationObjectID: conversation.objectID)
        return try context.count(for: request)
    }

    /// How many messages one `SELF IN` fetch of a mark-read batch names.
    nonisolated static let markReadFetchChunkSize = 500

    /// The messages of a mark-read batch that the store still has, by
    /// objectID, with their labels loaded. Call inside `context.perform`.
    ///
    /// One fetch per chunk, with the labels prefetched, replaces a row fault
    /// and a labels fault for every message: a newsletter chat opened with
    /// 5,000 unread took about 10,000 single-row round trips before its
    /// badge cleared (`docs/scalability-review.md`,
    /// `chat-open-unread-snapshot`). A chunk whose fetch fails marks nothing,
    /// as a message that could not be loaded did before.
    nonisolated private static func fetchMessagesWithLabels(
        _ messageIDs: [NSManagedObjectID],
        in context: NSManagedObjectContext
    ) -> [NSManagedObjectID: Message] {
        var messagesByID: [NSManagedObjectID: Message] = [:]
        messagesByID.reserveCapacity(messageIDs.count)

        var chunkStart = 0
        while chunkStart < messageIDs.count {
            let chunkEnd = min(chunkStart + markReadFetchChunkSize, messageIDs.count)
            let chunk = Array(messageIDs[chunkStart..<chunkEnd])
            chunkStart = chunkEnd

            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = NSPredicate(format: "SELF IN %@", chunk)
            request.relationshipKeyPathsForPrefetching = ["labels"]
            request.returnsObjectsAsFaults = false

            do {
                for message in try context.fetch(request) {
                    messagesByID[message.objectID] = message
                }
            } catch {
                Log.error(
                    "Failed to load a chunk of messages to mark as read",
                    category: .coreData,
                    error: error
                )
            }
        }
        return messagesByID
    }

    /// The label with this ID, or nil when the store has none. Throws when
    /// the fetch failed, which is not the same answer: a caller that took a
    /// failed read for a missing label changed the conversation and left the
    /// label on its messages.
    nonisolated private static func fetchLabel(
        id: String,
        in context: NSManagedObjectContext
    ) throws -> Label? {
        let request = Label.fetchRequest()
        request.predicate = LabelPredicates.id(id)
        return try context.fetch(request).first
    }

    nonisolated private static func applyArchivedConversationRollup(to conversation: Conversation, at date: Date) {
        conversation.archivedAt = date
        conversation.hasInbox = false
        conversation.inboxUnreadCount = 0
        conversation.latestInboxDate = nil
    }

    /// The ID a conversation-wide Gmail action may name for `message`, or nil
    /// when the row has no Gmail ID of its own.
    ///
    /// The user's own reply keeps the local UUID of its optimistic send until
    /// sync replaces it with Gmail's echo (`OutboundSendDeliveryState
    /// .localOptimisticMessageID`): while it sends, and for good once retained
    /// as "Not sent" or "Delivery unknown". That is not a Gmail message ID.
    /// One such ID in the single `batchModify` this action becomes made Gmail
    /// reject the whole request, and the processor abandons a non-retryable
    /// failure at once, so the archive or spam report never reached Gmail for
    /// any message in the conversation. Archive and Report Spam tapped during
    /// a send now run right after the optimistic row is created
    /// (`ChatConversationExitActionPolicy`), which made that the usual case.
    /// The row still takes the local change; its echo arrives as an outgoing
    /// message, which is never inbox presence.
    nonisolated private static func gmailMessageIDForConversationAction(_ message: Message) -> String? {
        guard !message.id.isEmpty,
              OutboundSendDeliveryState.localOptimisticMessageID(for: message) == nil else {
            return nil
        }
        return message.id
    }

    private func updateStarState(
        message: Message,
        isStarred: Bool,
        actionType: PendingAction.ActionType
    ) async {
        await performAccountWork { syncRun in
            guard let messageID = self.storedObjectIDs(of: [message], operation: actionType.rawValue)?.first else {
                return
            }
            // Starring changes no rollup. It takes the conversation's turn
            // because it writes the message's labels, as an archive of the
            // same message does from another context.
            let conversationKeys = Self.conversationKeys(for: [message.conversation?.objectID])
            await self.rollupMutationSerializer.perform(conversationKeys: conversationKeys) { [weak self] in
                guard let self,
                      let gmailMessageId = await self.performStarMutation(
                        messageID: messageID,
                        isStarred: isStarred,
                        actionType: actionType
                      ) else {
                    return
                }
                await self.queueReadStateAction(
                    type: actionType,
                    messageId: gmailMessageId,
                    within: syncRun
                )
            }
        }
    }

    /// Returns the message's Gmail ID, or nil when nothing was saved (the
    /// message is gone, is already in the asked-for state, or the save
    /// failed).
    private func performStarMutation(
        messageID: NSManagedObjectID,
        isStarred: Bool,
        actionType: PendingAction.ActionType
    ) async -> String? {
        let save = makeBackgroundSave()
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            guard let message = try? context.existingObject(with: messageID) as? Message else {
                return nil
            }
            let existingStarLabel = message.labels?.first(where: { $0.id == "STARRED" })
            guard isStarred != (existingStarLabel != nil) else { return nil }

            if isStarred {
                let starLabel: Label?
                do {
                    starLabel = try Self.fetchLabel(id: "STARRED", in: context)
                } catch {
                    // Not "no such label", which stars remotely only.
                    Log.error("Not starring: the STARRED label could not be read", category: .coreData, error: error)
                    return nil
                }
                if let starLabel {
                    message.addToLabels(starLabel)
                } else {
                    Log.warning("STARRED label not found locally; queueing remote star only", category: .message)
                }
            } else if let existingStarLabel {
                message.removeFromLabels(existingStarLabel)
            }

            message.localModifiedAt = Date()
            guard save(context, "\(actionType.rawValue) message") else {
                Log.error("Not queuing \(actionType.rawValue): local save failed", category: .message)
                context.rollback()
                return nil
            }
            return message.id
        }
    }
}
