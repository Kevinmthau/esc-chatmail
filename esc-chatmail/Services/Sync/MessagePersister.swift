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
    let saveHTML: (String, String) -> URL?
    let conversationManager: ConversationManager
    let conversationRouter: MessageConversationRouter
    let photoPrefetcher: @Sendable ([String]) async -> Void
    let inlineCIDPrefetchScheduler: @Sendable (InlineCIDAttachmentPrefetchRequest, NSManagedObjectContext) -> Void

    // MARK: - Initialization

    init(
        coreDataStack: CoreDataStack = .shared,
        messageProcessor: MessageProcessor = MessageProcessor(),
        htmlContentHandler: HTMLContentHandler = HTMLContentHandler(),
        saveHTML: ((String, String) -> URL?)? = nil,
        conversationManager: ConversationManager = ConversationManager(),
        conversationRouter: MessageConversationRouter? = nil,
        photoPrefetcher: (@Sendable ([String]) async -> Void)? = nil,
        inlineCIDPrefetchScheduler: (@Sendable (InlineCIDAttachmentPrefetchRequest, NSManagedObjectContext) -> Void)? = nil
    ) {
        self.coreDataStack = coreDataStack
        self.messageProcessor = messageProcessor
        self.htmlContentHandler = htmlContentHandler
        self.saveHTML = saveHTML ?? { html, messageId in
            htmlContentHandler.saveHTML(html, for: messageId)
        }
        self.conversationManager = conversationManager
        self.conversationRouter = conversationRouter ?? MessageConversationRouter(
            conversationManager: conversationManager
        )
        self.photoPrefetcher = photoPrefetcher ?? { emails in
            await ProfilePhotoResolver.shared.prefetchPhotos(for: emails)
        }
        self.inlineCIDPrefetchScheduler = inlineCIDPrefetchScheduler ?? { request, context in
            InlineCIDAttachmentPrefetchScheduler.schedule(request, in: context)
        }
    }

    /// Outcome of the side-effect-free preparation phase, ready for serialized persistence.
    enum PreparedMessage: Sendable {
        /// Message belongs to an excluded mailbox (spam/draft/trash) and should be removed locally.
        case excludedMailbox(id: String, label: String)
        /// Message was processed and is ready to be created or updated.
        case processed(ProcessedMessage)
        /// Processing failed; nothing to persist.
        case unprocessable(id: String)
    }

    // MARK: - Message Persistence

    /// Saves a Gmail message to Core Data.
    /// - Parameters:
    ///   - gmailMessage: The Gmail message to save
    ///   - labelIds: Pre-fetched label IDs (Sendable) used to scope label fetches inside `context.perform`.
    ///   - myAliases: Set of user's email aliases
    ///   - context: The Core Data context to save in
    func saveMessage(
        _ gmailMessage: GmailMessage,
        labelIds: Set<String>? = nil,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = [],
        modificationTransaction: ModificationTracker.Transaction? = nil,
        in context: NSManagedObjectContext
    ) async {
        let prepared = await prepareMessage(
            gmailMessage,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        )
        await persist(
            prepared,
            labelIds: labelIds,
            myAliases: myAliases,
            modificationTransaction: modificationTransaction,
            in: context
        )
    }

    /// Saves a batch of Gmail messages to Core Data.
    ///
    /// The expensive, side-effect-free preparation (`processGmailMessage`: HTML/text
    /// extraction, classification, large-body fetches) runs concurrently across the
    /// batch. Persistence then runs sequentially in the supplied order so that
    /// conversation routing (which reads already-persisted messages by `gmThreadId`)
    /// remains deterministic. Callers should pass messages already sorted into the
    /// desired persistence order (typically chronological).
    func saveMessages(
        _ gmailMessages: [GmailMessage],
        labelIds: Set<String>? = nil,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = [],
        modificationTransaction: ModificationTracker.Transaction? = nil,
        in context: NSManagedObjectContext
    ) async {
        guard !gmailMessages.isEmpty else { return }

        let prepared = await prepareMessagesConcurrently(
            gmailMessages,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        )

        for outcome in prepared {
            await persist(
                outcome,
                labelIds: labelIds,
                myAliases: myAliases,
                modificationTransaction: modificationTransaction,
                in: context
            )
        }
    }

    // MARK: - Preparation (concurrency-safe, no Core Data writes)

    /// Processes a Gmail message into a `PreparedMessage`. Performs no Core Data writes,
    /// so it is safe to run concurrently across many messages.
    nonisolated func prepareMessage(
        _ gmailMessage: GmailMessage,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async -> PreparedMessage {
        if let messageLabelIds = gmailMessage.labelIds,
           let excludedMailboxLabel = messageLabelIds.first(where: Self.excludedMailboxLabelIDs.contains) {
            return .excludedMailbox(id: gmailMessage.id, label: excludedMailboxLabel)
        }

        // Debug: Log incoming message details
        let fromHeader = gmailMessage.payload?.headers?.first(where: { $0.name.lowercased() == "from" })?.value ?? "unknown"
        let subjectHeader = gmailMessage.payload?.headers?.first(where: { $0.name.lowercased() == "subject" })?.value ?? "no subject"
        Log.debug("Processing: from=\(Log.redact(address: fromHeader)) subjLen=\(subjectHeader.count)", category: .sync)

        // Process the Gmail message (may fetch large body parts via API)
        guard let processedMessage = await messageProcessor.processGmailMessage(
            gmailMessage,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        ) else {
            return .unprocessable(id: gmailMessage.id)
        }

        return .processed(processedMessage)
    }

    /// Prepares messages concurrently with bounded parallelism, preserving input order.
    nonisolated func prepareMessagesConcurrently(
        _ gmailMessages: [GmailMessage],
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async -> [PreparedMessage] {
        let maxConcurrent = max(1, min(SyncConfig.maxConcurrentMessageProcessing, gmailMessages.count))

        return await withTaskGroup(of: (Int, PreparedMessage).self) { group in
            var results = [PreparedMessage?](repeating: nil, count: gmailMessages.count)
            var nextIndex = 0

            while nextIndex < maxConcurrent {
                let index = nextIndex
                let message = gmailMessages[index]
                group.addTask { [self] in
                    (index, await self.prepareMessage(
                        message,
                        myAliases: myAliases,
                        sendAsAliases: sendAsAliases
                    ))
                }
                nextIndex += 1
            }

            for await (index, prepared) in group {
                results[index] = prepared
                if nextIndex < gmailMessages.count {
                    let refillIndex = nextIndex
                    let message = gmailMessages[refillIndex]
                    group.addTask { [self] in
                        (refillIndex, await self.prepareMessage(
                            message,
                            myAliases: myAliases,
                            sendAsAliases: sendAsAliases
                        ))
                    }
                    nextIndex += 1
                }
            }

            return results.compactMap { $0 }
        }
    }

    // MARK: - Persistence (serialized on the actor)

    /// Persists a prepared message. Must run serially per context to keep conversation
    /// routing deterministic.
    private func persist(
        _ prepared: PreparedMessage,
        labelIds: Set<String>?,
        myAliases: Set<String>,
        modificationTransaction: ModificationTracker.Transaction?,
        in context: NSManagedObjectContext
    ) async {
        switch prepared {
        case .excludedMailbox(let id, let label):
            await deleteExistingMessageIfPresent(
                id: id,
                modificationTransaction: modificationTransaction,
                in: context
            )
            Log.debug("Skipping \(label.lowercased()) message: \(id)", category: .sync)

        case .unprocessable(let id):
            Log.warning("Failed to process message: \(id)", category: .sync)

        case .processed(let processedMessage):
            // Check for existing message and update if needed
            if await updateExistingMessage(
                processedMessage,
                labelIds: labelIds,
                modificationTransaction: modificationTransaction,
                in: context
            ) {
                return
            }

            // Create new message
            do {
                try await createNewMessage(
                    processedMessage,
                    labelIds: labelIds,
                    myAliases: myAliases,
                    modificationTransaction: modificationTransaction,
                    in: context
                )
            } catch {
                Log.error("Failed to create message \(processedMessage.id): \(error)", category: .sync)
            }
        }
    }
}

extension MessagePersister {
    static let excludedMailboxLabelIDs: Set<String> = ["SPAM", "DRAFT", "TRASH"]
}
