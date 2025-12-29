import Foundation
import CoreData

/// Handles persisting messages to Core Data
final class MessagePersister: @unchecked Sendable {
    let coreDataStack: CoreDataStack
    private let messageProcessor: MessageProcessor
    private let htmlContentHandler: HTMLContentHandler
    let conversationManager: ConversationManager

    /// Serial queue to protect access to modifiedConversationIDs
    /// This ensures thread-safe access to the shared mutable set
    private let modifiedConversationsQueue = DispatchQueue(label: "com.esc.chatmail.modifiedConversations")

    /// Tracks conversation IDs modified during current sync batch
    /// Access is protected by modifiedConversationsQueue for thread safety
    private var modifiedConversationIDs: Set<NSManagedObjectID> = []

    init(
        coreDataStack: CoreDataStack = .shared,
        messageProcessor: MessageProcessor = MessageProcessor(),
        htmlContentHandler: HTMLContentHandler = HTMLContentHandler(),
        conversationManager: ConversationManager = ConversationManager()
    ) {
        self.coreDataStack = coreDataStack
        self.messageProcessor = messageProcessor
        self.htmlContentHandler = htmlContentHandler
        self.conversationManager = conversationManager
    }

    /// Resets the modified conversations tracker - call at start of sync
    func resetModifiedConversations() {
        modifiedConversationsQueue.sync {
            modifiedConversationIDs.removeAll()
        }
    }

    /// Returns and clears the set of modified conversation IDs
    /// Thread-safe: Uses serial queue to protect access
    func getAndClearModifiedConversations() -> Set<NSManagedObjectID> {
        return modifiedConversationsQueue.sync {
            let result = modifiedConversationIDs
            modifiedConversationIDs.removeAll()
            return result
        }
    }

    /// Tracks a conversation as modified
    /// Thread-safe: Uses serial queue to protect access
    private func trackModifiedConversation(_ conversation: Conversation) {
        _ = modifiedConversationsQueue.sync {
            modifiedConversationIDs.insert(conversation.objectID)
        }
    }

    /// Saves a Gmail message to Core Data
    /// - Parameters:
    ///   - gmailMessage: The Gmail message to save
    ///   - labelCache: Pre-fetched label cache for efficient lookups
    ///   - myAliases: Set of user's email aliases
    ///   - context: The Core Data context to save in
    func saveMessage(
        _ gmailMessage: GmailMessage,
        labelCache: [String: Label]? = nil,
        myAliases: Set<String>,
        in context: NSManagedObjectContext
    ) async {
        // Skip messages in SPAM folder
        if let labelIds = gmailMessage.labelIds, labelIds.contains("SPAM") {
            Log.debug("Skipping spam message: \(gmailMessage.id)", category: .sync)
            return
        }

        // Debug: Log incoming message details
        let fromHeader = gmailMessage.payload?.headers?.first(where: { $0.name.lowercased() == "from" })?.value ?? "unknown"
        let subjectHeader = gmailMessage.payload?.headers?.first(where: { $0.name.lowercased() == "subject" })?.value ?? "no subject"
        Log.debug("Processing: from=\(fromHeader.prefix(40)) subj=\(subjectHeader.prefix(40))", category: .sync)

        // Process the Gmail message
        guard let processedMessage = messageProcessor.processGmailMessage(
            gmailMessage,
            myAliases: myAliases,
            in: context
        ) else {
            Log.warning("Failed to process message: \(gmailMessage.id)", category: .sync)
            return
        }

        // Check for existing message and update if needed
        if await updateExistingMessage(processedMessage, labelCache: labelCache, in: context) {
            return
        }

        // Create new message
        await createNewMessage(processedMessage, labelCache: labelCache, myAliases: myAliases, in: context)
    }

    /// Updates an existing message if it exists
    /// - Returns: true if an existing message was found and updated
    private func updateExistingMessage(
        _ processedMessage: ProcessedMessage,
        labelCache: [String: Label]?,
        in context: NSManagedObjectContext
    ) async -> Bool {
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", processedMessage.id)

        guard let existingMessage = try? context.fetch(request).first else {
            return false
        }

        // Update existing message properties that might have changed
        existingMessage.isUnread = processedMessage.isUnread
        existingMessage.snippet = processedMessage.snippet
        existingMessage.cleanedSnippet = processedMessage.cleanedSnippet

        // Update labels
        existingMessage.labels = nil
        for labelId in processedMessage.labelIds {
            let label: Label?
            if let cache = labelCache {
                label = cache[labelId]
            } else {
                label = await findLabel(id: labelId, in: context)
            }
            if let label = label {
                existingMessage.addToLabels(label)
            }
        }

        // Only add attachments if the message doesn't already have them
        let existingAttachments = existingMessage.typedAttachments
        if existingAttachments.isEmpty {
            for attachmentInfo in processedMessage.attachmentInfo {
                createAttachment(attachmentInfo, for: existingMessage, in: context)
            }
        }

        // Track the conversation as modified for rollup updates
        if let conversation = existingMessage.conversation {
            trackModifiedConversation(conversation)
        }

        Log.debug("Updated existing message: \(processedMessage.id)", category: .sync)
        return true
    }

    /// Creates a new message in Core Data
    private func createNewMessage(
        _ processedMessage: ProcessedMessage,
        labelCache: [String: Label]?,
        myAliases: Set<String>,
        in context: NSManagedObjectContext
    ) async {
        // Create conversation identity using Gmail threadId as primary key
        // This ensures stable conversation grouping that matches Gmail's threading
        let identity = conversationManager.createConversationIdentity(
            from: processedMessage.headers,
            gmThreadId: processedMessage.gmThreadId,
            myAliases: myAliases
        )
        let conversation = await conversationManager.findOrCreateConversation(for: identity, in: context)

        // Create Core Data message entity
        let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context) as! Message
        message.id = processedMessage.id
        message.gmThreadId = processedMessage.gmThreadId
        message.snippet = processedMessage.snippet
        message.cleanedSnippet = processedMessage.cleanedSnippet
        message.conversation = conversation
        message.internalDate = processedMessage.internalDate
        message.subject = processedMessage.headers.subject
        message.isFromMe = processedMessage.headers.isFromMe
        message.isUnread = processedMessage.isUnread
        message.isNewsletter = processedMessage.isNewsletter
        message.hasAttachments = processedMessage.hasAttachments

        // Store message threading headers
        message.setValue(processedMessage.headers.messageId, forKey: "messageId")
        message.setValue(processedMessage.headers.references.joined(separator: " "), forKey: "references")

        // Store plain text body for quoting in replies
        message.setValue(processedMessage.plainTextBody, forKey: "bodyText")

        // Store sender information for reply attribution
        if let from = processedMessage.headers.from {
            if let email = EmailNormalizer.extractEmail(from: from) {
                message.setValue(email, forKey: "senderEmail")
            }
            if let displayName = EmailNormalizer.extractDisplayName(from: from) {
                message.setValue(displayName, forKey: "senderName")
            }
        }

        // Save participants
        await saveParticipants(for: processedMessage, message: message, in: context)

        // Save labels
        var addedLabelIds: [String] = []
        let hasInboxLabel = processedMessage.labelIds.contains("INBOX")
        for labelId in processedMessage.labelIds {
            let label: Label?
            if let cache = labelCache {
                label = cache[labelId]
            } else {
                label = await findLabel(id: labelId, in: context)
            }
            if let label = label {
                message.addToLabels(label)
                addedLabelIds.append(labelId)
            }
        }
        Log.debug("New message \(processedMessage.id): labels=\(addedLabelIds), hasINBOX=\(hasInboxLabel), conversationId=\(conversation.id.uuidString)", category: .sync)

        // Save HTML content if present
        if let htmlBody = processedMessage.htmlBody {
            if let fileURL = htmlContentHandler.saveHTML(htmlBody, for: processedMessage.id) {
                message.bodyStorageURI = fileURL.absoluteString
            }
        }

        // Save attachment info
        for attachmentInfo in processedMessage.attachmentInfo {
            createAttachment(attachmentInfo, for: message, in: context)
        }

        // Update conversation's lastMessageDate to bump it to the top
        if conversation.lastMessageDate == nil || message.internalDate > conversation.lastMessageDate! {
            conversation.lastMessageDate = message.internalDate
            if message.isNewsletter, let subject = message.subject, !subject.isEmpty {
                conversation.snippet = subject
            } else {
                conversation.snippet = message.cleanedSnippet ?? message.snippet
            }
        }

        // Track the conversation as modified for rollup updates
        trackModifiedConversation(conversation)
    }

    /// Saves all participants for a message
    private func saveParticipants(
        for processedMessage: ProcessedMessage,
        message: Message,
        in context: NSManagedObjectContext
    ) async {
        if let from = processedMessage.headers.from {
            await saveParticipant(from: from, kind: .from, for: message, in: context)
        }
        for recipient in processedMessage.headers.to {
            let headerValue = "\(recipient.displayName ?? "") <\(recipient.email)>"
            await saveParticipant(from: headerValue, kind: .to, for: message, in: context)
        }
        for recipient in processedMessage.headers.cc {
            let headerValue = "\(recipient.displayName ?? "") <\(recipient.email)>"
            await saveParticipant(from: headerValue, kind: .cc, for: message, in: context)
        }
        for recipient in processedMessage.headers.bcc {
            let headerValue = "\(recipient.displayName ?? "") <\(recipient.email)>"
            await saveParticipant(from: headerValue, kind: .bcc, for: message, in: context)
        }
    }

    /// Saves a single participant using MessageParticipantFactory
    private func saveParticipant(
        from headerValue: String,
        kind: ParticipantKind,
        for message: Message,
        in context: NSManagedObjectContext
    ) async {
        _ = MessageParticipantFactory.create(
            from: headerValue,
            kind: kind,
            for: message,
            in: context
        )
    }

    /// Creates an attachment entity using AttachmentFactory
    private func createAttachment(
        _ info: AttachmentInfo,
        for message: Message,
        in context: NSManagedObjectContext
    ) {
        _ = AttachmentFactory.create(from: info, for: message, in: context)
    }

    /// Finds a label by ID
    private func findLabel(id: String, in context: NSManagedObjectContext) async -> Label? {
        let request = Label.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        do {
            let label = try context.fetch(request).first
            if label == nil {
                // Log missing labels for debugging - this can happen if labels haven't been synced yet
                Log.debug("Label '\(id)' not found in local cache", category: .sync)
            }
            return label
        } catch {
            Log.error("Error fetching label '\(id)'", category: .sync, error: error)
            return nil
        }
    }

}
