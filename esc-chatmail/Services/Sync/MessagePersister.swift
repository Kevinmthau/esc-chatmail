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

    /// Tracks conversation IDs modified during current sync batch.
    /// Actor isolation provides thread safety.
    var modifiedConversationIDs: Set<NSManagedObjectID> = []

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

    /// Resets the modified conversations tracker - call at start of sync.
    func resetModifiedConversations() {
        modifiedConversationIDs.removeAll()
    }

    /// Returns and clears the set of modified conversation IDs.
    func getAndClearModifiedConversations() -> Set<NSManagedObjectID> {
        let result = modifiedConversationIDs
        modifiedConversationIDs.removeAll()
        return result
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
        await createNewMessage(processedMessage, labelIds: labelIds, myAliases: myAliases, in: context)
    }
}
