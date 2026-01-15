import Foundation
import CoreData

/// Handles persisting messages to Core Data.
///
/// The service is split across multiple files for organization:
/// - `MessagePersister.swift` - Core structure and orchestration
/// - `MessagePersister+Updates.swift` - Updating existing messages
/// - `MessagePersister+Creation.swift` - Creating new messages
/// - `MessagePersister+Participants.swift` - Participant handling
/// - `MessagePersister+Helpers.swift` - Helper methods
actor MessagePersister {

    // MARK: - Properties

    let coreDataStack: CoreDataStack
    let messageProcessor: MessageProcessor
    let htmlContentHandler: HTMLContentHandler
    let conversationManager: ConversationManager

    // MARK: - Initialization

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

    // MARK: - Modified Conversations Tracking
    // Tracking is now delegated to ModificationTracker.shared for consolidated
    // tracking across MessagePersister and HistoryProcessor.

    /// Resets the modified conversations tracker - call at start of sync.
    func resetModifiedConversations() async {
        await ModificationTracker.shared.reset()
    }

    /// Returns and clears the set of modified conversation IDs.
    /// NOTE: Prefer using ModificationTracker.shared.getAndClearModifiedConversations() directly.
    func getAndClearModifiedConversations() async -> Set<NSManagedObjectID> {
        await ModificationTracker.shared.getAndClearModifiedConversations()
    }

    // MARK: - Message Persistence

    /// Saves a Gmail message to Core Data.
    /// - Parameters:
    ///   - gmailMessage: The Gmail message to save
    ///   - labelIds: Pre-fetched label IDs (Sendable). Labels are fetched inside context.perform for thread safety.
    ///   - myAliases: Set of user's email aliases
    ///   - context: The Core Data context to save in
    func saveMessage(
        _ gmailMessage: GmailMessage,
        labelIds: Set<String>? = nil,
        myAliases: Set<String>,
        in context: NSManagedObjectContext
    ) async {
        // Skip messages in SPAM folder
        if let labelIds = gmailMessage.labelIds, labelIds.contains("SPAM") {
            Log.debug("Skipping spam message: \(gmailMessage.id)", category: .sync)
            return
        }

        // Skip draft messages
        if let labelIds = gmailMessage.labelIds, labelIds.contains("DRAFT") {
            Log.debug("Skipping draft message: \(gmailMessage.id)", category: .sync)
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
        if await updateExistingMessage(processedMessage, labelIds: labelIds, in: context) {
            return
        }

        // Create new message
        do {
            try await createNewMessage(processedMessage, labelIds: labelIds, myAliases: myAliases, in: context)
        } catch {
            Log.error("Failed to create message \(gmailMessage.id): \(error)", category: .sync)
        }
    }
}
