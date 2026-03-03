import Foundation
import CoreData
import Combine

/// ViewModel for ChatView - manages chat state and message operations
@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var replyText = ""
    @Published var replyingTo: Message?
    @Published var messageToForward: Message?
    @Published var resolvedDisplayName: String?

    // MARK: - Composed Services

    var contactManager: ChatContactManager

    // MARK: - Dependencies

    let conversation: Conversation
    let messageActions: MessageActions
    let sendService: GmailSendService

    private let coreDataStack: CoreDataStack
    private let syncEngine: SyncEngine
    private let authSession: AuthSession
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Task Management

    private let taskManager = ViewModelTaskManager()
    private let prefetchTaskManager = ViewModelTaskManager()

    // MARK: - Initialization

    /// Primary initializer using Dependencies container
    init(conversation: Conversation, deps: Dependencies? = nil) {
        let dependencies = deps ?? .shared
        self.conversation = conversation
        self.coreDataStack = dependencies.coreDataStack
        self.syncEngine = dependencies.syncEngine
        self.authSession = dependencies.authSession
        self.messageActions = dependencies.makeMessageActions()
        self.sendService = dependencies.makeSendService()
        self.contactManager = ChatContactManager()

        // Forward child observable changes to trigger view updates
        forwardChanges(from: contactManager, storing: &cancellables)
    }

    // MARK: - Message Actions

    /// Marks all unread messages in the conversation as read
    /// Uses batch operation to prevent race condition with new messages arriving during marking
    func markConversationAsRead(messageObjectIDs: [NSManagedObjectID]) {
        // Immediately clear the unread count in UI (optimistic update)
        conversation.inboxUnreadCount = 0

        let messageActions = self.messageActions
        let conversationID = conversation.objectID
        taskManager.runDetached("markConversationAsRead") {
            // Use batch operation for atomic update - prevents race condition
            await messageActions.markMessagesAsReadBatch(messageIDs: messageObjectIDs, conversationID: conversationID)
        }
    }

    func toggleMessageRead(_ message: Message) {
        let messageID = message.objectID
        taskManager.run("toggleRead-\(messageID)") { [weak self] in
            guard let self = self else { return }
            if message.isUnread {
                await messageActions.markAsRead(message: message)
            } else {
                await messageActions.markAsUnread(message: message)
            }
        }
    }

    func archiveMessage(_ message: Message) {
        let messageID = message.objectID
        taskManager.run("archiveMessage-\(messageID)") { [weak self] in
            guard let self = self else { return }
            await messageActions.archive(message: message)
        }
    }

    func archiveConversation() {
        taskManager.run("archiveConversation") { [weak self] in
            guard let self = self else { return }
            await messageActions.archiveConversation(conversation: conversation)
        }
    }

    func starMessage(_ message: Message) {
        let messageID = message.objectID
        taskManager.run("starMessage-\(messageID)") { [weak self] in
            guard let self = self else { return }
            await messageActions.star(message: message)
        }
    }

    // MARK: - Conversation Settings

    func reportSpam() {
        taskManager.run("reportSpam") { [weak self] in
            guard let self = self else { return }
            await messageActions.reportSpamConversation(conversation: conversation)
        }
    }

    // MARK: - Reply Actions

    func setReplyingTo(_ message: Message) {
        replyingTo = message
    }

    /// Sets the initial replyingTo message when the conversation loads
    func initializeReplyingTo(lastMessage: Message?) {
        guard replyingTo == nil, let lastMessage = lastMessage else { return }
        replyingTo = lastMessage
    }

    /// Updates replyingTo when a new message arrives with a different subject
    func updateReplyingToIfNewSubject(lastMessage: Message?) {
        guard let lastMessage = lastMessage else { return }

        // If user cleared replyingTo (tapped X), don't auto-update
        guard let currentReplyingTo = replyingTo else { return }

        // If the new message has a different subject, update to it
        let currentSubject = currentReplyingTo.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newSubject = lastMessage.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if currentSubject != newSubject {
            replyingTo = lastMessage
        }
    }

    func setMessageToForward(_ message: Message) {
        messageToForward = message
    }

    /// Sends a reply with optional attachments
    func sendReply(with attachments: [Attachment]) async {
        let trimmedReplyText = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReplyText.isEmpty || !attachments.isEmpty else { return }

        let replyData = ChatReplyBar.ReplyData(
            from: conversation,
            replyingTo: replyingTo,
            body: trimmedReplyText,
            attachments: attachments,
            currentUserEmail: authSession.userEmail ?? ""
        )

        guard !replyData.recipients.isEmpty else { return }

        let optimisticMessage: Message
        do {
            optimisticMessage = try await sendService.createOptimisticMessage(
                to: replyData.recipients,
                body: trimmedReplyText,
                subject: replyData.subject,
                threadId: replyData.threadId,
                attachments: attachments,
                existingConversation: conversation
            )
        } catch {
            Log.error("Failed to create optimistic message for reply", category: .message, error: error)
            return
        }
        let optimisticMessageID = optimisticMessage.id
        let sendService = self.sendService
        let attachmentInfos = attachments.map { sendService.attachmentToInfo($0) }

        // Clear composer immediately after optimistic insertion.
        replyText = ""
        replyingTo = nil

        let recipients = replyData.recipients
        let subject = replyData.subject
        let threadId = replyData.threadId
        let inReplyTo = replyData.inReplyTo
        let references = replyData.references
        let originalMessage = replyData.originalMessage
        let syncEngine = self.syncEngine
        let taskManager = self.taskManager

        taskManager.run("sendReply-\(optimisticMessageID)", priority: .userInitiated) {
            do {
                let result: GmailSendService.SendResult

                if let subject, let threadId, !threadId.isEmpty {
                    result = try await sendService.sendReply(
                        to: recipients,
                        body: trimmedReplyText,
                        subject: subject,
                        threadId: threadId,
                        inReplyTo: inReplyTo,
                        references: references,
                        originalMessage: originalMessage,
                        attachmentInfos: attachmentInfos
                    )
                } else {
                    result = try await sendService.sendNew(
                        to: recipients,
                        body: trimmedReplyText,
                        attachmentInfos: attachmentInfos
                    )
                }

                if let optimisticMessage = await sendService.fetchMessage(byID: optimisticMessageID) {
                    sendService.updateOptimisticMessage(optimisticMessage, with: result)
                    sendService.markAttachmentsAsUploaded(optimisticMessage.attachmentsArray)
                }

                // Trigger sync to fetch server canonical data. Failure is non-critical.
                taskManager.runDetached("postSendSync-\(optimisticMessageID)") {
                    do {
                        try await syncEngine.performIncrementalSync()
                    } catch {
                        Log.warning("Post-send sync failed - sent message will appear on next sync: \(error.localizedDescription)", category: .sync)
                    }
                }
            } catch {
                if let optimisticMessage = await sendService.fetchMessage(byID: optimisticMessageID) {
                    sendService.handleFailedOptimisticMessage(optimisticMessage)
                }
                Log.error("Failed to send reply", category: .message, error: error)
            }
        }
    }

    // MARK: - Prefetch Operations

    /// Prefetches text content and contacts for the given messages.
    /// Call from ChatView.onAppear with recent messages.
    func prefetchRecentContent(messageIds: [String], senderEmails: [String]) {
        // Batch prefetch text content for recent messages (eliminates N+1 queries)
        prefetchTaskManager.runDetached("prefetchText") {
            await ProcessedTextCache.shared.prefetch(messageIds: messageIds)
        }

        // Batch prefetch contacts to avoid thundering herd on first load
        let uniqueEmails = Array(Set(senderEmails))
        prefetchTaskManager.runDetached("prefetchContacts") {
            await ContactsResolver.shared.prewarm(emails: uniqueEmails)
        }
    }

    /// Cancels all prefetch tasks. Call from ChatView.onDisappear.
    func cancelPrefetch() {
        prefetchTaskManager.cancelAll()
    }

    // MARK: - Display Name Resolution

    /// Loads the resolved display name for the conversation participants.
    /// Call from ChatView on appear.
    func loadResolvedDisplayName() {
        prefetchTaskManager.run("displayName") { [weak self] in
            guard let self = self,
                  let myEmail = authSession.userEmail else { return }
            let info = await ParticipantLoader.shared.loadParticipants(
                from: conversation,
                currentUserEmail: myEmail,
                maxParticipants: 4
            )
            resolvedDisplayName = info.formattedDisplayName
        }
    }
}
