import Foundation
import CoreData

/// Handles persisting messages to Core Data
final class MessagePersister: @unchecked Sendable {
    private let coreDataStack: CoreDataStack
    private let messageProcessor: MessageProcessor
    private let htmlContentHandler: HTMLContentHandler
    let conversationManager: ConversationManager

    /// Tracks conversation IDs modified during current sync batch
    /// Access should be synchronized via the sync context
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
        modifiedConversationIDs.removeAll()
    }

    /// Returns and clears the set of modified conversation IDs
    func getAndClearModifiedConversations() -> Set<NSManagedObjectID> {
        let result = modifiedConversationIDs
        modifiedConversationIDs.removeAll()
        return result
    }

    /// Tracks a conversation as modified
    private func trackModifiedConversation(_ conversation: Conversation) {
        modifiedConversationIDs.insert(conversation.objectID)
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
            print("Skipping spam message: \(gmailMessage.id)")
            return
        }

        // Process the Gmail message
        guard let processedMessage = messageProcessor.processGmailMessage(
            gmailMessage,
            myAliases: myAliases,
            in: context
        ) else {
            return
        }

        // Check if message is from before installation
        let installationTimestamp = KeychainService.shared.getOrCreateInstallationTimestamp()
        if processedMessage.internalDate < installationTimestamp {
            print("Skipping message from before installation: \(processedMessage.id)")
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
        let existingAttachments = existingMessage.value(forKey: "attachments") as? NSSet
        if existingAttachments == nil || existingAttachments!.count == 0 {
            for attachmentInfo in processedMessage.attachmentInfo {
                createAttachment(attachmentInfo, for: existingMessage, in: context)
            }
        }

        // Track the conversation as modified for rollup updates
        if let conversation = existingMessage.conversation {
            trackModifiedConversation(conversation)
        }

        print("Updated existing message: \(processedMessage.id)")
        return true
    }

    /// Creates a new message in Core Data
    private func createNewMessage(
        _ processedMessage: ProcessedMessage,
        labelCache: [String: Label]?,
        myAliases: Set<String>,
        in context: NSManagedObjectContext
    ) async {
        // Create conversation identity and find/create conversation
        let identity = conversationManager.createConversationIdentity(
            from: processedMessage.headers,
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
        for labelId in processedMessage.labelIds {
            let label: Label?
            if let cache = labelCache {
                label = cache[labelId]
            } else {
                label = await findLabel(id: labelId, in: context)
            }
            if let label = label {
                message.addToLabels(label)
            }
        }

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

    /// Saves a single participant
    private func saveParticipant(
        from headerValue: String,
        kind: ParticipantKind,
        for message: Message,
        in context: NSManagedObjectContext
    ) async {
        guard let email = EmailNormalizer.extractEmail(from: headerValue) else { return }
        let normalizedEmail = EmailNormalizer.normalize(email)
        let displayName = EmailNormalizer.extractDisplayName(from: headerValue)

        let person = conversationManager.findOrCreatePerson(
            email: normalizedEmail,
            displayName: displayName,
            in: context
        )

        let participant = NSEntityDescription.insertNewObject(
            forEntityName: "MessageParticipant",
            into: context
        ) as! MessageParticipant
        participant.id = UUID()
        participant.participantKind = kind
        participant.person = person
        participant.message = message
    }

    /// Creates an attachment entity
    private func createAttachment(
        _ info: AttachmentInfo,
        for message: Message,
        in context: NSManagedObjectContext
    ) {
        let attachment = NSEntityDescription.insertNewObject(
            forEntityName: "Attachment",
            into: context
        ) as! Attachment
        attachment.setValue(info.id, forKey: "id")
        attachment.setValue(info.filename, forKey: "filename")
        attachment.setValue(info.mimeType, forKey: "mimeType")
        attachment.setValue(Int64(info.size), forKey: "byteSize")
        attachment.setValue("queued", forKey: "stateRaw")
        attachment.setValue(message, forKey: "message")
    }

    /// Finds a label by ID
    private func findLabel(id: String, in context: NSManagedObjectContext) async -> Label? {
        let request = Label.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        return try? context.fetch(request).first
    }

    // MARK: - Label Operations

    /// Prefetches all labels into a dictionary for efficient lookups
    func prefetchLabels(in context: NSManagedObjectContext) async -> [String: Label] {
        return await context.perform {
            let request = Label.fetchRequest()
            request.fetchBatchSize = 100
            guard let labels = try? context.fetch(request) else {
                return [:]
            }
            var labelCache: [String: Label] = [:]
            for label in labels {
                labelCache[label.id] = label
            }
            print("Prefetched \(labelCache.count) labels into cache")
            return labelCache
        }
    }

    /// Saves labels from Gmail API to Core Data
    func saveLabels(_ gmailLabels: [GmailLabel], in context: NSManagedObjectContext) async {
        for gmailLabel in gmailLabels {
            let label = NSEntityDescription.insertNewObject(
                forEntityName: "Label",
                into: context
            ) as! Label
            label.id = gmailLabel.id
            label.name = gmailLabel.name
        }
    }

    // MARK: - Account Operations

    /// Saves or updates account information
    func saveAccount(
        profile: GmailProfile,
        aliases: [String],
        in context: NSManagedObjectContext
    ) async -> Account {
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", profile.emailAddress)

        if let existing = try? context.fetch(request).first {
            existing.aliasesArray = aliases
            existing.historyId = profile.historyId
            print("Updated existing account: \(profile.emailAddress)")
            return existing
        }

        let account = NSEntityDescription.insertNewObject(
            forEntityName: "Account",
            into: context
        ) as! Account
        account.id = profile.emailAddress
        account.email = profile.emailAddress
        account.historyId = profile.historyId
        account.aliasesArray = aliases
        print("Created new account: \(profile.emailAddress) with historyId: \(profile.historyId)")
        return account
    }

    /// Fetches account data
    func fetchAccountData() async throws -> AccountData? {
        return try await coreDataStack.performBackgroundTask { context in
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            let accounts = try context.fetch(request)
            guard let account = accounts.first else {
                return nil
            }
            return AccountData(
                historyId: account.historyId,
                email: account.email,
                aliases: account.aliasesArray
            )
        }
    }

    /// Updates account's history ID
    func updateAccountHistoryId(_ historyId: String) async {
        do {
            try await coreDataStack.performBackgroundTask { [weak self] context in
                guard let self = self else { return }
                let request = Account.fetchRequest()
                request.fetchLimit = 1
                if let account = try context.fetch(request).first {
                    account.historyId = historyId
                    try self.coreDataStack.save(context: context)
                }
            }
        } catch {
            print("Failed to save history ID: \(error)")
            // Attempt retry once
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                try await coreDataStack.performBackgroundTask { [weak self] context in
                    guard let self = self else { return }
                    let request = Account.fetchRequest()
                    request.fetchLimit = 1
                    if let account = try context.fetch(request).first {
                        account.historyId = historyId
                        try self.coreDataStack.save(context: context)
                        print("Successfully saved history ID on retry")
                    }
                }
            } catch {
                print("Failed to save history ID after retry: \(error)")
            }
        }
    }
}

/// Data structure for account information
struct AccountData {
    let historyId: String?
    let email: String
    let aliases: [String]
}
