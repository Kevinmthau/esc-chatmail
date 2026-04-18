import Foundation
import CoreData
import Combine

/// ViewModel for ChatView - manages chat state and message operations
@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var replyText = ""
    @Published var replyingTo: Message?
    @Published var forwardComposeContext: ComposeForwardModeContext?
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
    private let composeForwardModeContextBuilder: ComposeForwardModeContextBuilder

    private let authSession: AuthSession
    private let htmlContentHandler: HTMLContentHandler
    private let participantLoader: ParticipantLoader
    private let conversationObjectID: NSManagedObjectID
    private let conversationContext: NSManagedObjectContext?
    private let conversationDisplayNameHint: String?
    private let replyOptimisticConversation: OptimisticConversationReference
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
        self.htmlContentHandler = dependencies.htmlContentHandler
        self.participantLoader = dependencies.participantLoader
        self.conversationObjectID = conversation.objectID
        self.conversationContext = conversation.managedObjectContext
        self.conversationDisplayNameHint = conversation.displayName
        self.replyOptimisticConversation = .existingConversation(
            ConversationReference(objectID: conversation.objectID)
        )
        self.processedTextCache = dependencies.processedTextCache
        self.contactsResolver = dependencies.contactsResolver
        self.messageActions = dependencies.makeMessageActions()
        self.outboundMessageCoordinator = dependencies.makeOutboundMessageCoordinator()
        self.outboundAttachmentContextBuilder = dependencies.makeOutboundAttachmentContextBuilder()
        self.outboundReplyContextBuilder = dependencies.makeOutboundReplyContextBuilder()
        self.composeForwardModeContextBuilder = dependencies.makeComposeForwardModeContextBuilder()
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

    func markConversationAsReadIfNeeded() {
        guard conversation.inboxUnreadCount > 0 else { return }

        let unreadMessageIDs = messageActions.snapshotUnreadConversationMessageObjectIDs(
            conversationID: conversation.id
        )
        markConversationAsRead(messageObjectIDs: unreadMessageIDs)
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
        do {
            forwardComposeContext = try composeForwardModeContextBuilder.build(
                input: makeForwardModeInput(message)
            )
        } catch {
            Log.error("Failed to prepare forward compose context", category: .message, error: error)
        }
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
                            conversationObjectID: conversation.objectID,
                            replyingToMessageObjectID: replyingTo?.objectID,
                            optimisticConversation: replyOptimisticConversation
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
                    participantHash: self.conversation.participantHash,
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

    private func makeForwardModeInput(_ message: Message) throws -> ComposeForwardModeContextBuilder.Input {
        let attachments = try makeForwardAttachmentPayload(message)

        return ComposeForwardModeContextBuilder.Input(
            source: makeForwardSource(message),
            forwardedInlineAttachmentInfos: attachments.inlineAttachmentInfos,
            forwardedRegularAttachments: attachments.regularAttachments
        )
    }

    private func makeForwardSource(_ message: Message) -> MessageFormatBuilder.ForwardSource {
        MessageFormatBuilder.ForwardSource(
            id: message.id,
            subject: message.subject,
            internalDate: message.internalDate,
            isFromMe: message.isFromMe,
            bodyText: message.bodyTextValue,
            snippet: message.snippet,
            originalHTML: loadOriginalHTML(for: message),
            participants: Array(message.conversation?.participants ?? []).compactMap { participant in
                guard let person = participant.person else { return nil }
                return .init(
                    email: person.email,
                    displayName: person.displayName
                )
            }
        )
    }

    private func loadOriginalHTML(for message: Message) -> String? {
        if let html = htmlContentHandler.loadHTML(for: message.id) {
            return html
        }

        guard let bodyStorageURI = message.bodyStorageURI else {
            return nil
        }

        if htmlContentHandler.migrateIfNeeded(from: bodyStorageURI),
           let migratedHTML = htmlContentHandler.loadHTML(for: message.id) {
            return migratedHTML
        }

        guard let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
              FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        return htmlContentHandler.loadHTML(from: resolvedURL)
    }

    private func makeForwardAttachmentPayload(_ message: Message) throws -> ForwardAttachmentPayload {
        let attachments = message.attachmentsForForwarding
        let inlineAttachments = attachments.filter { attachment in
            guard let contentId = attachment.contentId else { return false }
            return !contentId.isEmpty
        }
        let regularAttachments = attachments.filter { attachment in
            guard let contentId = attachment.contentId else { return true }
            return contentId.isEmpty
        }

        return ForwardAttachmentPayload(
            inlineAttachmentInfos: try outboundAttachmentContextBuilder.buildInlineAttachmentInfos(
                from: inlineAttachments
            ),
            regularAttachments: regularAttachments.map(makeForwardAttachmentSnapshot)
        )
    }

    private func makeForwardAttachmentSnapshot(_ attachment: Attachment) -> ForwardAttachmentSnapshot {
        ForwardAttachmentSnapshot(
            filename: attachment.filenameValue,
            mimeType: attachment.mimeTypeValue,
            byteSize: attachment.byteSize,
            localURL: attachment.localURLValue,
            previewURL: attachment.previewURLValue,
            width: attachment.width,
            height: attachment.height,
            pageCount: attachment.pageCount
        )
    }

    private struct ForwardAttachmentPayload {
        let inlineAttachmentInfos: [GmailSendService.AttachmentInfo]
        let regularAttachments: [ForwardAttachmentSnapshot]
    }
}
