import Foundation
import CoreData

/// Handles persisting messages to Core Data
final class MessagePersister: @unchecked Sendable {
    private let coreDataStack: CoreDataStack
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
            Log.debug("Prefetched \(labelCache.count) labels into cache", category: .sync)
            return labelCache
        }
    }

    /// Saves labels from Gmail API to Core Data with upsert logic
    /// Labels are upserted by ID to prevent duplicate Label rows
    func saveLabels(_ gmailLabels: [GmailLabel], in context: NSManagedObjectContext) async {
        await context.perform {
            // Fetch all existing labels into a dictionary for efficient lookup
            let request = Label.fetchRequest()
            let existingLabels = (try? context.fetch(request)) ?? []
            var labelDict = Dictionary(uniqueKeysWithValues: existingLabels.map { ($0.id, $0) })

            var insertedCount = 0
            var updatedCount = 0

            for gmailLabel in gmailLabels {
                if let existingLabel = labelDict[gmailLabel.id] {
                    // Update existing label if name changed
                    if existingLabel.name != gmailLabel.name {
                        existingLabel.name = gmailLabel.name
                        updatedCount += 1
                    }
                } else {
                    // Insert new label
                    let label = NSEntityDescription.insertNewObject(
                        forEntityName: "Label",
                        into: context
                    ) as! Label
                    label.id = gmailLabel.id
                    label.name = gmailLabel.name
                    labelDict[gmailLabel.id] = label
                    insertedCount += 1
                }
            }

            Log.debug("Labels: inserted=\(insertedCount), updated=\(updatedCount), total=\(labelDict.count)", category: .sync)
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
            Log.debug("Updated existing account: \(profile.emailAddress)", category: .sync)
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
        Log.info("Created new account: \(profile.emailAddress) with historyId: \(profile.historyId)", category: .sync)
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

    /// Updates account's history ID in the provided context WITHOUT saving
    /// Use this for transactional updates where historyId should be saved with other changes
    /// - Parameters:
    ///   - historyId: The new history ID to set
    ///   - context: The Core Data context to update in (will not be saved)
    func setAccountHistoryId(_ historyId: String, in context: NSManagedObjectContext) async {
        await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            if let account = try? context.fetch(request).first {
                account.historyId = historyId
                Log.debug("Set historyId to \(historyId) in context (pending save)", category: .sync)
            } else {
                Log.warning("No account found to set history ID", category: .sync)
            }
        }
    }

    /// Updates account's history ID in a SEPARATE transaction
    /// WARNING: Use setAccountHistoryId(_:in:) for transactional sync updates
    /// This method is only for standalone historyId updates outside of sync
    /// - Parameter historyId: The new history ID to save
    /// - Returns: true if the save succeeded, false if it failed after retries
    @available(*, deprecated, message: "Use setAccountHistoryId(_:in:) for transactional sync updates")
    @discardableResult
    func updateAccountHistoryId(_ historyId: String) async -> Bool {
        var lastError: Error?

        // First attempt
        do {
            try await coreDataStack.performBackgroundTask { [weak self] context in
                guard let self = self else { return }
                let request = Account.fetchRequest()
                request.fetchLimit = 1
                if let account = try context.fetch(request).first {
                    account.historyId = historyId
                    try self.coreDataStack.save(context: context)
                    Log.debug("Successfully updated history ID to: \(historyId)", category: .sync)
                } else {
                    Log.warning("No account found to update history ID", category: .sync)
                }
            }
            return true
        } catch {
            lastError = error
            Log.warning("Failed to save history ID (attempt 1): \(error.localizedDescription)", category: .sync)
        }

        // Retry with backoff
        for attempt in 2...3 {
            do {
                // Exponential backoff: 500ms, 1s
                let delay = UInt64(250_000_000 * (1 << (attempt - 1)))
                try await Task.sleep(nanoseconds: delay)

                try await coreDataStack.performBackgroundTask { [weak self] context in
                    guard let self = self else { return }
                    let request = Account.fetchRequest()
                    request.fetchLimit = 1
                    if let account = try context.fetch(request).first {
                        account.historyId = historyId
                        try self.coreDataStack.save(context: context)
                        Log.debug("Successfully saved history ID on retry attempt \(attempt)", category: .sync)
                    }
                }
                return true
            } catch {
                lastError = error
                Log.warning("Failed to save history ID (attempt \(attempt)): \(error.localizedDescription)", category: .sync)
            }
        }

        Log.error("Failed to save history ID after all retries. Last error: \(lastError?.localizedDescription ?? "unknown")", category: .sync)
        return false
    }
}

/// Data structure for account information
struct AccountData {
    let historyId: String?
    let email: String
    let aliases: [String]
}
