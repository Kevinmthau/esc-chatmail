import Foundation
import CoreData

/// Per-`saveMessages` buffer for source conversations whose rollups became
/// stale after a message reroute.
///
/// Deferring the repairs batches one rollup pass per save instead of one per
/// reroute. The synchronous will-save observer drains the buffer on the
/// context's queue before ANY save of the supplied context (batch-boundary
/// saves, or future callers that save mid-batch), so relationship moves and
/// their repaired rollups cross every durability boundary together.
/// (Historically the conversation-creation serializer saved the caller's
/// context mid-batch; it now commits shells in its own sibling context, but
/// the observer remains the guard for any other mid-batch save.)
final class MessagePersisterReroutedSourceRollupBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var conversationIDs = Set<NSManagedObjectID>()
    private var willSaveObserver: (any NSObjectProtocol)?

    init(observing context: NSManagedObjectContext) {
        willSaveObserver = NotificationCenter.default.addObserver(
            forName: NSManagedObjectContext.willSaveObjectsNotification,
            object: context,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let savingContext = notification.object as? NSManagedObjectContext else {
                return
            }
            self.drainAndApply(in: savingContext)
        }
    }

    func register(_ conversationID: NSManagedObjectID) {
        lock.lock()
        conversationIDs.insert(conversationID)
        lock.unlock()
    }

    /// Must be called on `context`'s queue.
    func drainAndApply(in context: NSManagedObjectContext) {
        let pendingConversationIDs = takeConversationIDs()
        guard !pendingConversationIDs.isEmpty else { return }

        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "SELF IN %@", pendingConversationIDs)
        request.relationshipKeyPathsForPrefetching = ["messages", "messages.labels"]

        let conversations: [Conversation]
        do {
            conversations = try context.fetch(request)
        } catch {
            Log.error(
                "Failed to prefetch rerouted source conversation rollups; falling back to registered objects",
                category: .coreData,
                error: error
            )
            conversations = pendingConversationIDs.compactMap {
                try? context.existingObject(with: $0) as? Conversation
            }
        }

        for conversation in conversations {
            ConversationRollupSnapshot.make(
                from: conversation.messages ?? []
            ).apply(to: conversation)
        }
    }

    func stopObserving() {
        let observer: (any NSObjectProtocol)?
        lock.lock()
        observer = willSaveObserver
        willSaveObserver = nil
        lock.unlock()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    deinit {
        stopObserving()
    }

    private func takeConversationIDs() -> Set<NSManagedObjectID> {
        lock.lock()
        defer { lock.unlock() }
        let pendingConversationIDs = conversationIDs
        conversationIDs.removeAll(keepingCapacity: true)
        return pendingConversationIDs
    }
}

/// Handles persisting messages to Core Data.
///
/// The service is split across multiple files for organization:
/// - `MessagePersister.swift` - Core structure and orchestration
/// - `MessagePersister+Updates.swift` - Updating existing messages
/// - `MessagePersister+Creation.swift` - Creating new messages
/// - `MessagePersister+Participants.swift` - Participant handling
/// - `MessagePersister+Helpers.swift` - Helper methods
actor MessagePersister {
    struct RemoteCommittedSendMutationResolution {
        let recordObjectIDs: [NSManagedObjectID]
        let anchoredListConversationObjectID: NSManagedObjectID?
        let anchoredListId: String?
        let shouldConsumeAfterPersistence: Bool
    }

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
        /// A large body part could not be fetched (rate limit, network, auth).
        /// The failure may succeed later, so persistence must report `.failed`
        /// — persisting now would store a permanently body-less message behind
        /// an advancing cursor. Distinct from `.unprocessable`, whose payload
        /// defect repeats on every fetch.
        case bodyFetchFailed(id: String)
    }

    // MARK: - Message Persistence

    /// Saves a Gmail message to Core Data.
    /// - Parameters:
    ///   - gmailMessage: The Gmail message to save
    ///   - labelIds: Pre-fetched label IDs (Sendable) used to scope label fetches inside `context.perform`.
    ///   - myAliases: Set of user's email aliases
    ///   - context: The Core Data context to save in
    @discardableResult
    func saveMessage(
        _ gmailMessage: GmailMessage,
        labelIds: Set<String>? = nil,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = [],
        modificationTransaction: ModificationTracker.Transaction? = nil,
        in context: NSManagedObjectContext
    ) async throws -> MessagePersistDisposition {
        let prepared = try await prepareMessage(
            gmailMessage,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        )
        let remoteCommittedSendMutation: RemoteCommittedSendMutationResolution?
        if case .processed(let processedMessage) = prepared {
            remoteCommittedSendMutation = await remoteCommittedSendMutationResolutions(
                for: [processedMessage.id],
                in: context
            )[processedMessage.id]
        } else {
            remoteCommittedSendMutation = nil
        }
        return try await persist(
            prepared,
            labelIds: labelIds,
            myAliases: myAliases,
            modificationTransaction: modificationTransaction,
            remoteCommittedSendMutation: remoteCommittedSendMutation,
            in: context
        )
    }

    /// Saves a batch of Gmail messages to Core Data.
    ///
    /// The expensive, side-effect-free preparation (`processGmailMessage`: HTML/text
    /// extraction, classification, large-body fetches) runs concurrently across the
    /// batch. Persistence then runs sequentially in the supplied order so that
    /// conversation creation, inbox seeding, and rollup ordering remain
    /// deterministic. Callers should pass messages already sorted into the
    /// desired persistence order (typically chronological).
    /// - Returns: the per-ID persistence report; every message in
    ///   `gmailMessages` lands in exactly one bucket. Throws only on
    ///   run-fatal conditions — schema/model failures that would fail every
    ///   message identically, or `APIError.quotaExhausted` from a large-body
    ///   fetch (account-scoped; the batch gets no verdict and the run aborts).
    @discardableResult
    func saveMessages(
        _ gmailMessages: [GmailMessage],
        labelIds: Set<String>? = nil,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = [],
        modificationTransaction: ModificationTracker.Transaction? = nil,
        in context: NSManagedObjectContext
    ) async throws -> MessagePersistenceReport {
        guard !gmailMessages.isEmpty else { return .empty }

        let prepared = try await prepareMessagesConcurrently(
            gmailMessages,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        )
        let processedMessageIDs = Set(prepared.compactMap { outcome -> String? in
            guard case .processed(let processedMessage) = outcome else { return nil }
            return processedMessage.id
        })
        let remoteCommittedSendMutations = await remoteCommittedSendMutationResolutions(
            for: processedMessageIDs,
            in: context
        )

        // One batch fetch primes the context's Person cache so the
        // per-participant find-or-create calls during persistence become
        // dictionary hits instead of individual SQLite fetches.
        let participantEmails = Self.participantEmails(in: prepared)
        if !participantEmails.isEmpty {
            await context.perform {
                _ = PersonFactory.prefetch(emails: participantEmails, in: context)
            }
        }

        let reroutedSourceRollupBuffer = MessagePersisterReroutedSourceRollupBuffer(
            observing: context
        )
        defer { reroutedSourceRollupBuffer.stopObserving() }

        var report = MessagePersistenceReport()
        for outcome in prepared {
            let disposition = try await persist(
                outcome,
                labelIds: labelIds,
                myAliases: myAliases,
                modificationTransaction: modificationTransaction,
                reroutedSourceRollupBuffer: reroutedSourceRollupBuffer,
                remoteCommittedSendMutation: {
                    guard case .processed(let processedMessage) = outcome else {
                        return nil
                    }
                    return remoteCommittedSendMutations[processedMessage.id]
                }(),
                in: context
            )
            report.record(Self.messageId(of: outcome), disposition)
        }

        // Take pending IDs only after entering the context queue. Otherwise an
        // interleaved context save could observe an empty buffer before this
        // final repair reaches the queue.
        await context.perform {
            reroutedSourceRollupBuffer.drainAndApply(in: context)
        }
        return report
    }

    private nonisolated static func messageId(of prepared: PreparedMessage) -> String {
        switch prepared {
        case .excludedMailbox(let id, _): return id
        case .unprocessable(let id): return id
        case .bodyFetchFailed(let id): return id
        case .processed(let processedMessage): return processedMessage.id
        }
    }

    /// Collects every participant email that persistence will look up for the
    /// prepared batch (sender plus to/cc/bcc recipients), normalized to match
    /// PersonFactory's cache keys.
    nonisolated static func participantEmails(in prepared: [PreparedMessage]) -> [String] {
        var emails = Set<String>()
        for outcome in prepared {
            guard case .processed(let processedMessage) = outcome else { continue }
            let headers = processedMessage.headers
            if let from = headers.from, let email = EmailNormalizer.extractEmail(from: from) {
                emails.insert(EmailNormalizer.normalize(email))
            }
            for recipient in headers.to + headers.cc + headers.bcc {
                emails.insert(EmailNormalizer.normalize(recipient.email))
            }
        }
        emails.remove("")
        return Array(emails)
    }

    // MARK: - Preparation (concurrency-safe, no Core Data writes)

    /// Processes a Gmail message into a `PreparedMessage`. Performs no Core Data writes,
    /// so it is safe to run concurrently across many messages.
    /// - Throws: `APIError.quotaExhausted` when a large-body fetch reports the
    ///   account's quota exhausted. Account-scoped: the run must abort with no
    ///   per-message verdict (mirrors `MessageFetcher.fetchBatch`'s quota
    ///   throw) so the next scheduled sync retries after the window resets.
    ///   Every other body-fetch failure is a per-message verdict:
    ///   `.bodyFetchFailed`, persisted as `.failed`.
    nonisolated func prepareMessage(
        _ gmailMessage: GmailMessage,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async throws -> PreparedMessage {
        if let messageLabelIds = gmailMessage.labelIds,
           let excludedMailboxLabel = messageLabelIds.first(where: Self.excludedMailboxLabelIDs.contains) {
            return .excludedMailbox(id: gmailMessage.id, label: excludedMailboxLabel)
        }

        // Debug: Log incoming message details
        let fromHeader = gmailMessage.payload?.headers?.first(where: { $0.name.lowercased() == "from" })?.value ?? "unknown"
        let subjectHeader = gmailMessage.payload?.headers?.first(where: { $0.name.lowercased() == "subject" })?.value ?? "no subject"
        Log.debug("Processing: from=\(Log.redact(address: fromHeader)) subjLen=\(subjectHeader.count)", category: .sync)

        // Process the Gmail message (may fetch large body parts via API)
        let processedMessage: ProcessedMessage?
        do {
            processedMessage = try await messageProcessor.processGmailMessage(
                gmailMessage,
                myAliases: myAliases,
                sendAsAliases: sendAsAliases
            )
        } catch {
            if let apiError = error as? APIError, case .quotaExhausted = apiError {
                throw apiError
            }
            if error is CancellationError {
                // A cancelled run proves nothing about the message; recording
                // a failure would be a spurious blocking verdict (cancelled
                // FETCHES likewise record nothing — see MessageFetcher).
                throw error
            }
            Log.warning("Body fetch failed for message \(Log.hashIdentifier(gmailMessage.id)): \(error)", category: .sync)
            return .bodyFetchFailed(id: gmailMessage.id)
        }

        guard let processedMessage else {
            return .unprocessable(id: gmailMessage.id)
        }

        return .processed(processedMessage)
    }

    /// Prepares messages concurrently with bounded parallelism, preserving input order.
    /// - Throws: `APIError.quotaExhausted` from any message's preparation. The
    ///   first quota signal cancels the remaining preparation tasks and the
    ///   whole batch gets no verdict — the run aborts before persistence, so
    ///   the unadvanced cursor re-fetches the batch next sync.
    nonisolated func prepareMessagesConcurrently(
        _ gmailMessages: [GmailMessage],
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async throws -> [PreparedMessage] {
        let maxConcurrent = max(1, min(SyncConfig.maxConcurrentMessageProcessing, gmailMessages.count))

        return try await withThrowingTaskGroup(of: (Int, PreparedMessage).self) { group in
            var results = [PreparedMessage?](repeating: nil, count: gmailMessages.count)
            var nextIndex = 0

            while nextIndex < maxConcurrent {
                let index = nextIndex
                let message = gmailMessages[index]
                group.addTask { [self] in
                    (index, try await self.prepareMessage(
                        message,
                        myAliases: myAliases,
                        sendAsAliases: sendAsAliases
                    ))
                }
                nextIndex += 1
            }

            while let (index, prepared) = try await group.next() {
                results[index] = prepared
                if nextIndex < gmailMessages.count {
                    let refillIndex = nextIndex
                    let message = gmailMessages[refillIndex]
                    group.addTask { [self] in
                        (refillIndex, try await self.prepareMessage(
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
        reroutedSourceRollupBuffer: MessagePersisterReroutedSourceRollupBuffer? = nil,
        remoteCommittedSendMutation: RemoteCommittedSendMutationResolution?,
        in context: NSManagedObjectContext
    ) async throws -> MessagePersistDisposition {
        switch prepared {
        case .excludedMailbox(let id, let label):
            let removedCleanly = await deleteExistingMessageIfPresent(
                id: id,
                modificationTransaction: modificationTransaction,
                in: context
            )
            guard removedCleanly else {
                // A stale local row may remain; the cursor must not treat
                // this as a clean exclusion.
                return .failed
            }
            Log.debug("Skipping \(label.lowercased()) message: \(id)", category: .sync)
            return .excluded

        case .unprocessable(let id):
            Log.warning("Failed to process message: \(id)", category: .sync)
            return .unprocessable

        case .bodyFetchFailed(let id):
            // Transient body-fetch failure: persisting would freeze an empty
            // body behind an advancing cursor, so block the cursor instead
            // and let the next sync retry the whole message.
            Log.warning("Large body fetch failed for message \(Log.hashIdentifier(id)); deferring persistence", category: .sync)
            return .failed

        case .processed(let processedMessage):
            // Check for existing message and update if needed
            switch await updateExistingMessageOutcome(
                processedMessage,
                labelIds: labelIds,
                myAliases: myAliases,
                modificationTransaction: modificationTransaction,
                reroutedSourceRollupBuffer: reroutedSourceRollupBuffer,
                remoteCommittedSendMutation: remoteCommittedSendMutation,
                in: context
            ) {
            case .updated:
                return .persisted
            case .lookupFailed:
                // Creating here could insert a duplicate of a row that
                // exists but could not be read.
                return .failed
            case .notPresent:
                break
            }

            // Create new message
            do {
                try await createNewMessage(
                    processedMessage,
                    labelIds: labelIds,
                    myAliases: myAliases,
                    modificationTransaction: modificationTransaction,
                    remoteCommittedSendMutation: remoteCommittedSendMutation,
                    in: context
                )
                return .persisted
            } catch CoreDataError.entityCreationFailed(let entity) {
                // Model/schema mismatch: every message in the run fails the
                // same way, so this is run-fatal, not a per-message verdict.
                throw CoreDataError.entityCreationFailed(entity)
            } catch {
                Log.error("Failed to create message \(processedMessage.id): \(error)", category: .sync)
                return .failed
            }
        }
    }
}

extension MessagePersister {
    static let excludedMailboxLabelIDs: Set<String> = ["SPAM", "DRAFT", "TRASH"]
}
