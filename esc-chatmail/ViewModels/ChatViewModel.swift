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

    // MARK: - Composed Services

    var contactManager: ChatContactManager

    // MARK: - Dependencies

    let conversation: Conversation
    let messageActions: MessageActions
    let sendService: GmailSendService

    private let coreDataStack: CoreDataStack
    private let syncEngine: SyncEngine
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    /// Primary initializer using Dependencies container
    init(conversation: Conversation, deps: Dependencies? = nil) {
        let dependencies = deps ?? .shared
        self.conversation = conversation
        self.coreDataStack = dependencies.coreDataStack
        self.syncEngine = dependencies.syncEngine
        self.messageActions = dependencies.makeMessageActions()
        self.sendService = dependencies.makeSendService()
        self.contactManager = ChatContactManager()

        // Forward child observable changes to trigger view updates
        contactManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Message Actions

    /// Marks all unread messages in the conversation as read
    func markConversationAsRead(messageObjectIDs: [NSManagedObjectID]) {
        // Immediately clear the unread count in UI (optimistic update)
        conversation.inboxUnreadCount = 0

        let conversationID = conversation.objectID

        Task.detached { [coreDataStack, messageActions] in
            let context = coreDataStack.newBackgroundContext()
            await context.perform {
                if let conv = try? context.existingObject(with: conversationID) as? Conversation {
                    conv.inboxUnreadCount = 0
                    try? context.save()
                }
            }

            // Mark individual messages as read
            for messageID in messageObjectIDs {
                await messageActions.markAsRead(messageID: messageID)
            }
        }
    }

    func toggleMessageRead(_ message: Message) {
        Task {
            if message.isUnread {
                await messageActions.markAsRead(message: message)
            } else {
                await messageActions.markAsUnread(message: message)
            }
        }
    }

    func archiveMessage(_ message: Message) {
        Task {
            await messageActions.archive(message: message)
        }
    }

    func archiveConversation() {
        Task {
            await messageActions.archiveConversation(conversation: conversation)
        }
    }

    func starMessage(_ message: Message) {
        Task {
            await messageActions.star(message: message)
        }
    }

    // MARK: - Conversation Settings

    func togglePin() {
        conversation.pinned.toggle()
        do {
            try coreDataStack.save(context: coreDataStack.viewContext)
        } catch {
            Log.error("Failed to toggle pin", category: .ui, error: error)
            conversation.pinned.toggle()
        }
    }

    func toggleMute() {
        conversation.muted.toggle()
        do {
            try coreDataStack.save(context: coreDataStack.viewContext)
        } catch {
            Log.error("Failed to toggle mute", category: .ui, error: error)
            conversation.muted.toggle()
        }
    }

    // MARK: - Reply Actions

    func setReplyingTo(_ message: Message) {
        replyingTo = message
    }

    func setMessageToForward(_ message: Message) {
        messageToForward = message
    }

    /// Sends a reply with optional attachments
    func sendReply(with attachments: [Attachment]) async {
        guard !replyText.isEmpty || !attachments.isEmpty else { return }

        let replyData = ChatReplyBar.ReplyData(
            from: conversation,
            replyingTo: replyingTo,
            body: replyText,
            attachments: attachments,
            currentUserEmail: AuthSession.shared.userEmail ?? ""
        )

        guard !replyData.recipients.isEmpty else { return }

        let currentReplyText = replyText
        let optimisticMessage = await sendService.createOptimisticMessage(
            to: replyData.recipients,
            body: currentReplyText,
            subject: replyData.subject,
            threadId: replyData.threadId,
            attachments: attachments
        )
        let optimisticMessageID = optimisticMessage.id

        do {
            let result: GmailSendService.SendResult
            let attachmentInfos = attachments.map { sendService.attachmentToInfo($0) }

            if let subject = replyData.subject {
                result = try await sendService.sendReply(
                    to: replyData.recipients,
                    body: currentReplyText,
                    subject: subject,
                    threadId: replyData.threadId ?? "",
                    inReplyTo: replyData.inReplyTo,
                    references: replyData.references,
                    originalMessage: replyData.originalMessage,
                    attachmentInfos: attachmentInfos
                )
            } else {
                result = try await sendService.sendNew(
                    to: replyData.recipients,
                    body: currentReplyText,
                    attachmentInfos: attachmentInfos
                )
            }

            if let optimisticMessage = sendService.fetchMessage(byID: optimisticMessageID) {
                sendService.updateOptimisticMessage(optimisticMessage, with: result)
            }

            if !attachments.isEmpty {
                sendService.markAttachmentsAsUploaded(attachments)
            }

            replyText = ""
            replyingTo = nil

            // Trigger sync to fetch the sent message from Gmail
            let syncEngine = self.syncEngine
            Task.detached {
                try? await syncEngine.performIncrementalSync()
            }
        } catch {
            if let optimisticMessage = sendService.fetchMessage(byID: optimisticMessageID) {
                sendService.deleteOptimisticMessage(optimisticMessage)
            }
            Log.error("Failed to send reply", category: .message, error: error)
        }
    }
}
