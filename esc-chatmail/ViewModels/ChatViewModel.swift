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
    @Published var messageToViewInFull: Message?
    @Published var resolvedDisplayName: String?
    @Published var effectiveParticipantCount: Int?

    // MARK: - Composed Services

    var contactManager: ChatContactManager

    // MARK: - Dependencies

    let conversation: Conversation
    let messageActions: MessageActions
    private let outboundMessageCoordinator: any OutboundMessageCoordinating
    private let outboundAttachmentContextBuilder: OutboundAttachmentContextBuilder
    private let outboundReplyContextBuilder: OutboundReplyContextBuilder

    private let authSession: AuthSession
    private let participantLoader: ParticipantLoader
    private let conversationObjectID: NSManagedObjectID
    private let conversationContext: NSManagedObjectContext?
    private let conversationDisplayNameHint: String?
    private let processedTextCache: ProcessedTextCache
    private let contactsResolver: any ContactsResolving
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Task Management

    private let taskManager = ViewModelTaskManager()
    private let prefetchTaskManager = ViewModelTaskManager()

    var isEffectivelyOneToOneConversation: Bool {
        if let effectiveParticipantCount {
            return effectiveParticipantCount <= 1
        }

        return conversation.conversationType == .oneToOne
    }

    // MARK: - Initialization

    /// Primary initializer using Dependencies container
    init(conversation: Conversation, deps: Dependencies? = nil) {
        let dependencies = deps ?? .shared
        self.conversation = conversation
        self.authSession = dependencies.authSession
        self.participantLoader = dependencies.participantLoader
        self.conversationObjectID = conversation.objectID
        self.conversationContext = conversation.managedObjectContext
        self.conversationDisplayNameHint = conversation.displayName
        self.processedTextCache = dependencies.processedTextCache
        self.contactsResolver = dependencies.contactsResolver
        self.messageActions = dependencies.makeMessageActions()
        self.outboundMessageCoordinator = dependencies.makeOutboundMessageCoordinator()
        self.outboundAttachmentContextBuilder = dependencies.makeOutboundAttachmentContextBuilder()
        self.outboundReplyContextBuilder = dependencies.makeOutboundReplyContextBuilder()
        self.contactManager = dependencies.makeChatContactManager()

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

    func openFullMessage(_ message: Message) {
        Log.info("Opening full message for \(message.id)", category: .ui)
        messageToViewInFull = message
    }

    func dismissFullMessage() {
        Log.info("Dismissed full message view", category: .ui)
        messageToViewInFull = nil
    }

    /// Sends a reply with optional attachments
    func sendReply(with attachments: [Attachment]) async {
        let trimmedReplyText = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReplyText.isEmpty || !attachments.isEmpty else { return }

        let result: OutboundMessageResult?
        do {
            let attachmentContexts = try outboundAttachmentContextBuilder.buildSendAttachments(
                from: attachments
            )
            result = try await outboundMessageCoordinator.send(
                .reply(
                    .init(
                        context: outboundReplyContextBuilder.build(
                            conversation: conversation,
                            replyingTo: replyingTo
                        ),
                        body: trimmedReplyText,
                        attachments: attachmentContexts
                    )
                )
            )
        } catch {
            Log.error("Failed to create optimistic message for reply", category: .message, error: error)
            return
        }
        guard result != nil else { return }

        // Clear composer immediately after optimistic insertion.
        replyText = ""
        replyingTo = nil
    }

    // MARK: - Prefetch Operations

    /// Prefetches text content and contacts for the given messages.
    /// Call from ChatView.onAppear with recent messages.
    func prefetchRecentContent(messageIds: [String], senderEmails: [String]) {
        // Batch prefetch text content for recent messages (eliminates N+1 queries)
        let processedTextCache = self.processedTextCache
        prefetchTaskManager.runDetached("prefetchText") {
            await processedTextCache.prefetch(messageIds: messageIds)
        }

        // Batch prefetch contacts to avoid thundering herd on first load
        let uniqueEmails = Array(Set(senderEmails))
        let contactsResolver = self.contactsResolver
        prefetchTaskManager.runDetached("prefetchContacts") {
            await contactsResolver.prewarm(emails: uniqueEmails)
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
                  let myEmail = self.authSession.userEmail else { return }
            let info: ParticipantLoader.ParticipantInfo
            if let conversationContext = self.conversationContext {
                info = await self.participantLoader.loadParticipants(
                    from: self.conversationObjectID,
                    in: conversationContext,
                    currentUserEmail: myEmail,
                    maxParticipants: 4,
                    fallbackDisplayName: self.conversationDisplayNameHint
                )
            } else {
                info = await self.participantLoader.loadParticipants(
                    from: self.conversation,
                    currentUserEmail: myEmail,
                    maxParticipants: 4
                )
            }

            self.resolvedDisplayName = info.formattedDisplayName
            self.effectiveParticipantCount = info.totalUniqueParticipants
        }
    }
}
