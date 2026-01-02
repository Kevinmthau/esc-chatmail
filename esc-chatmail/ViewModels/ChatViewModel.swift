import Foundation
import CoreData
import Contacts
import ContactsUI
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

    // Contact action sheet state
    @Published var showingContactActionSheet = false
    @Published var personForContactAction: Person?

    // Add to existing contact flow state
    @Published var showingContactPicker = false
    @Published var personForExistingContact: Person?

    // MARK: - Dependencies

    let conversation: Conversation
    let messageActions: MessageActions
    let sendService: GmailSendService

    private let coreDataStack: CoreDataStack
    private let syncEngine: SyncEngine

    // MARK: - Initialization

    /// Primary initializer using Dependencies container
    init(conversation: Conversation, deps: Dependencies? = nil) {
        let dependencies = deps ?? .shared
        self.conversation = conversation
        self.coreDataStack = dependencies.coreDataStack
        self.syncEngine = dependencies.syncEngine
        self.messageActions = dependencies.makeMessageActions()
        self.sendService = dependencies.makeSendService()
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

    /// Called when tapping the add contact button - shows action sheet
    func showContactActionSheet(for person: Person) {
        personForContactAction = person
        showingParticipantsList = false
        showingContactActionSheet = true
    }

    /// Called when user selects "Create New Contact"
    func createNewContact() {
        guard let person = personForContactAction else { return }
        prepareContactToAdd(for: person)
        personForContactAction = nil
        showingContactActionSheet = false
    }

    /// Called when user selects "Add to Existing Contact"
    func addToExistingContact() {
        guard let person = personForContactAction else { return }
        personForExistingContact = person
        showingContactActionSheet = false
        showingContactPicker = true
    }

    /// Called when user picks a contact from the picker
    func handleContactSelected(_ contact: CNContact) {
        guard let person = personForExistingContact else { return }

        // Fetch full contact with required keys
        let contactStore = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactViewController.descriptorForRequiredKeys()
        ]

        do {
            let fullContact = try contactStore.unifiedContact(
                withIdentifier: contact.identifier,
                keysToFetch: keysToFetch
            )
            personForExistingContact = nil
            showingContactPicker = false
            ContactPresenter.shared.addEmailToContact(existingContact: fullContact, emailToAdd: person.email)
        } catch {
            Log.error("Failed to fetch contact for editing", category: .ui, error: error)
            personForExistingContact = nil
            showingContactPicker = false
        }
    }

    /// Called when user cancels the contact picker
    func handleContactPickerCancelled() {
        personForExistingContact = nil
        showingContactPicker = false
    }

    /// Called when tapping on an existing contact (green checkmark)
    func editExistingContact(identifier: String) {
        // Don't dismiss participants list - it causes a race condition with contact presentation
        // The contact card presents on top, and user can dismiss participants list after
        ContactPresenter.shared.presentContact(identifier: identifier)
    }
}

// MARK: - Contact Wrapper for Identifiable
struct ContactWrapper: Identifiable {
    let id = UUID()
    let contact: CNMutableContact
}

