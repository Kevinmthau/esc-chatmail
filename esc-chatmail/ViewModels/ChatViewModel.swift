import Foundation
import CoreData
import Contacts
import Combine

/// ViewModel for ChatView - manages chat state and message operations
@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var replyText = ""
    @Published var replyingTo: Message?
    @Published var messageToForward: Message?
    @Published var contactToAdd: ContactWrapper?
    @Published var showingParticipantsList = false

    // MARK: - Dependencies

    let conversation: Conversation
    let messageActions: MessageActions
    let sendService: GmailSendService

    private let coreDataStack: CoreDataStack

    // MARK: - Initialization

    init(
        conversation: Conversation,
        coreDataStack: CoreDataStack = .shared
    ) {
        self.conversation = conversation
        self.coreDataStack = coreDataStack
        self.messageActions = MessageActions()
        self.sendService = GmailSendService(viewContext: coreDataStack.viewContext)
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
            print("Failed to toggle pin: \(error)")
            conversation.pinned.toggle()
        }
    }

    func toggleMute() {
        conversation.muted.toggle()
        do {
            try coreDataStack.save(context: coreDataStack.viewContext)
        } catch {
            print("Failed to toggle mute: \(error)")
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
            Task.detached {
                try? await SyncEngine.shared.performIncrementalSync()
            }
        } catch {
            if let optimisticMessage = sendService.fetchMessage(byID: optimisticMessageID) {
                sendService.deleteOptimisticMessage(optimisticMessage)
            }
            print("Failed to send reply: \(error)")
        }
    }

    // MARK: - Contact Actions

    func prepareContactToAdd(for person: Person) {
        let contact = CNMutableContact()

        if let displayName = person.displayName, !displayName.isEmpty {
            let components = displayName.components(separatedBy: " ")
            if components.count >= 2 {
                contact.givenName = components[0]
                contact.familyName = components.dropFirst().joined(separator: " ")
            } else {
                contact.givenName = displayName
            }
        }

        let email = person.email
        contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]

        showingParticipantsList = false
        contactToAdd = ContactWrapper(contact: contact)
    }
}

// MARK: - Contact Wrapper for Identifiable
struct ContactWrapper: Identifiable {
    let id = UUID()
    let contact: CNMutableContact
}
