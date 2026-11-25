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
    struct SupersededOptimisticMessage {
        let optimisticMessageID: String
        let newlyInsertedConversation: Bool
    }

    struct RemoteCommittedSendMutationResolution {
        let recordObjectIDs: [NSManagedObjectID]
        let supersededOptimisticMessages: [NSManagedObjectID: SupersededOptimisticMessage]
        let anchoredListConversationObjectID: NSManagedObjectID?
        let anchoredListId: String?
        let shouldConsumeAfterPersistence: Bool
    }

    // MARK: - Properties

    let coreDataStack: CoreDataStack
    let messageProcessor: MessageProcessor
    let htmlContentHandler: HTMLContentHandler
    /// Writes a message's HTML body. Returns the reason when it could not, because each reason
    /// gets a different verdict (`dispositionAfterBodyWriteFailure`).
    let saveHTML: (String, String) -> HTMLSaveResult
    let conversationManager: ConversationManager
    let conversationRouter: MessageConversationRouter
    let photoPrefetcher: @Sendable ([String]) async -> Void
    let inlineCIDPrefetchScheduler: @Sendable (InlineCIDAttachmentPrefetchRequest, NSManagedObjectContext) -> Void

    // MARK: - Initialization

    init(
        coreDataStack: CoreDataStack = .shared,
        messageProcessor: MessageProcessor = MessageProcessor(),
        htmlContentHandler: HTMLContentHandler = HTMLContentHandler(),
        saveHTML: ((String, String) -> HTMLSaveResult)? = nil,
        conversationManager: ConversationManager = ConversationManager(),
        conversationRouter: MessageConversationRouter? = nil,
        photoPrefetcher: (@Sendable ([String]) async -> Void)? = nil,
        inlineCIDPrefetchScheduler: (@Sendable (InlineCIDAttachmentPrefetchRequest, NSManagedObjectContext) -> Void)? = nil
    ) {
        self.coreDataStack = coreDataStack
        self.messageProcessor = messageProcessor
        self.htmlContentHandler = htmlContentHandler
        self.saveHTML = saveHTML ?? { html, messageId in
            htmlContentHandler.saveHTMLResult(html, for: messageId)
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
        /// Preserve its RFC Message-ID so an excluded echo can still resolve an
        /// in-flight/ambiguous optimistic send by deterministic identity.
        case excludedMailbox(id: String, label: String, rfcMessageID: String?)
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
        do {
            remoteCommittedSendMutation = try await remoteCommittedSendMutationResolutions(
                for: Self.remoteSendEchoMessageIDs(in: [prepared]),
                sentMessageIDsByRemoteID: Self.sentMessageIDsByRemoteID(in: [prepared]),
                in: context
            )[Self.messageId(of: prepared)]
        } catch {
            // The lookup cannot be collapsed into "no matching mutation": that
            // could advance a cursor while an optimistic graph remains hidden
            // behind an unreadable route table.
            Log.error(
                "Failed to resolve remote committed send mutation",
                category: .coreData,
                error: error
            )
            return .failed
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
    ///   message identically, or an account-scoped API failure from a
    ///   large-body fetch (the batch gets no verdict and the run aborts).
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
        let remoteCommittedSendMutations: [
            String: RemoteCommittedSendMutationResolution
        ]
        do {
            remoteCommittedSendMutations = try await remoteCommittedSendMutationResolutions(
                for: Self.remoteSendEchoMessageIDs(in: prepared),
                sentMessageIDsByRemoteID: Self.sentMessageIDsByRemoteID(in: prepared),
                in: context
            )
        } catch {
            Log.error(
                "Failed to resolve remote committed send mutations",
                category: .coreData,
                error: error
            )
            var report = MessagePersistenceReport()
            for outcome in prepared {
                report.record(Self.messageId(of: outcome), .failed)
            }
            return report
        }

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
                remoteCommittedSendMutation: remoteCommittedSendMutations[
                    Self.messageId(of: outcome)
                ],
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
        case .excludedMailbox(let id, _, _): return id
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

    nonisolated static func sentMessageIDsByRemoteID(
        in processedMessages: [ProcessedMessage]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for message in processedMessages
            where message.headers.isFromMe && message.labelIds.contains("SENT") {
            guard let messageID = message.headers.messageId,
                  !messageID.isEmpty else {
                continue
            }
            result[message.id] = messageID
        }
        return result
    }

    /// IDs eligible to resolve a retained optimistic send. Failed preparation
    /// outcomes must not consume a mutation because no remote verdict was
    /// durably applied for them.
    private nonisolated static func remoteSendEchoMessageIDs(
        in prepared: [PreparedMessage]
    ) -> Set<String> {
        Set(prepared.compactMap { outcome in
            switch outcome {
            case .processed(let message):
                return message.id
            case .excludedMailbox(let id, _, _):
                return id
            case .unprocessable, .bodyFetchFailed:
                return nil
            }
        })
    }

    /// RFC Message-IDs used for exact deterministic echo matching. Processed
    /// messages retain the stricter SENT/from-me gate; excluded messages cannot
    /// be fully processed, but their raw header is still sufficient to decode
    /// the optimistic UUID and match the corresponding mutation record.
    private nonisolated static func sentMessageIDsByRemoteID(
        in prepared: [PreparedMessage]
    ) -> [String: String] {
        var result = sentMessageIDsByRemoteID(
            in: prepared.compactMap { outcome in
                guard case .processed(let message) = outcome else { return nil }
                return message
            }
        )
        for outcome in prepared {
            guard case .excludedMailbox(let id, _, let rfcMessageID) = outcome,
                  let rfcMessageID,
                  MimeBuilder.optimisticMessageID(from: rfcMessageID) != nil else {
                continue
            }
            result[id] = rfcMessageID
        }
        return result
    }

    // MARK: - Preparation (concurrency-safe, no Core Data writes)

    /// Processes a Gmail message into a `PreparedMessage`. Performs no Core Data writes,
    /// so it is safe to run concurrently across many messages.
    /// - Throws: authentication, revoked-credential, or quota errors from a
    ///   large-body fetch. These are account-scoped: the run must abort with no
    ///   per-message verdict (mirroring `MessageFetcher.fetchBatch`) so account
    ///   recovery happens before the message is attempted again.
    ///   Every other body-fetch failure is a per-message verdict:
    ///   `.bodyFetchFailed`, persisted as `.failed`.
    nonisolated func prepareMessage(
        _ gmailMessage: GmailMessage,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async throws -> PreparedMessage {
        if let messageLabelIds = gmailMessage.labelIds,
           let excludedMailboxLabel = messageLabelIds.first(where: Self.excludedMailboxLabelIDs.contains) {
            let rfcMessageID = gmailMessage.payload?.headers?.first {
                $0.name.caseInsensitiveCompare("Message-ID") == .orderedSame
            }?.value
            return .excludedMailbox(
                id: gmailMessage.id,
                label: excludedMailboxLabel,
                rfcMessageID: rfcMessageID
            )
        }

        // Debug: Log incoming message details. Both header lookups live inside
        // the autoclosure so they only run when debug logging is enabled.
        Log.debug("Processing: from=\(Log.redact(address: gmailMessage.payload?.headers?.first(where: { $0.name.lowercased() == "from" })?.value ?? "unknown")) subjLen=\((gmailMessage.payload?.headers?.first(where: { $0.name.lowercased() == "subject" })?.value ?? "no subject").count)", category: .sync)

        // Process the Gmail message (may fetch large body parts via API)
        let processedMessage: ProcessedMessage?
        do {
            processedMessage = try await messageProcessor.processGmailMessage(
                gmailMessage,
                myAliases: myAliases,
                sendAsAliases: sendAsAliases
            )
        } catch {
            if let apiError = error as? APIError, apiError.isAccountScopedSyncAbort {
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

        guard var processedMessage else {
            return .unprocessable(id: gmailMessage.id)
        }

        // The pre-run is one more cleanup of the whole body: a cancelled run
        // stops ahead of it rather than after it (no verdict, as above).
        try Task.checkCancellation()
        // The processor's pre-run, taken from the cleanup its preview already
        // ran, is kept when it is for the exact string persistence saves;
        // otherwise (stub processors, hand-built values) it is computed here.
        if let prerun = processedMessage.richContentPrerun,
           prerun.html == processedMessage.storedHTML,
           Self.richContentPrerunApplies(to: processedMessage) {
            return .processed(processedMessage)
        }
        processedMessage.richContentPrerun = Self.richContentPrerun(for: processedMessage)
        return .processed(processedMessage)
    }

    /// Runs the rich-content classifier in the concurrent preparation phase,
    /// on the exact string persistence will save, so stamping the verdict
    /// (`stampRichContentVerdict`) does not run a DOM cleanup in the strictly
    /// sequential persistence phase. `MessageProcessor.processGmailMessage`
    /// normally supplies it from the cleanup its preview derivation ran over
    /// that same string; this computes it where it did not.
    ///
    /// Skipped when the answer cannot matter (`richContentPrerunApplies`).
    nonisolated static func richContentPrerun(for processedMessage: ProcessedMessage) -> RichContentPrerun? {
        guard richContentPrerunApplies(to: processedMessage),
              let html = processedMessage.storedHTML else {
            return nil
        }
        return RichContentPrerun(
            html: html,
            isRich: RichContentClassifier.hasGenuineRichContentAfterCleanup(html)
        )
    }

    /// Whether a pre-run's answer can matter: there is stored HTML, own rows are
    /// never rich, and a body that reads like a newsletter's fallback text
    /// decides the verdict without the classifier once the HTML is stored.
    nonisolated static func richContentPrerunApplies(to processedMessage: ProcessedMessage) -> Bool {
        !processedMessage.headers.isFromMe &&
            processedMessage.storedHTML != nil &&
            !NewsletterFallbackText.looksLikeFallbackText(
                processedMessage.plainTextBody ?? processedMessage.snippet
            )
    }

    /// Prepares messages concurrently with bounded parallelism, preserving input order.
    /// - Throws: an account-scoped API error from any message's preparation.
    ///   The first signal cancels the remaining preparation tasks and the
    ///   whole batch gets no verdict — the run aborts before persistence, so
    ///   the unadvanced cursor re-fetches the batch after account recovery.
    nonisolated func prepareMessagesConcurrently(
        _ gmailMessages: [GmailMessage],
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async throws -> [PreparedMessage] {
        let maxConcurrent = max(1, min(SyncConfig.maxConcurrentMessageProcessing, gmailMessages.count))

        return try await withThrowingTaskGroup(of: (Int, PreparedMessage).self) { group in
            var results = [PreparedMessage?](repeating: nil, count: gmailMessages.count)
            var nextIndex = 0
            var running = 0
            // At most one message whose text body is oversized is prepared at
            // a time: its derivation reads the whole body several times and
            // holds what it builds until the batch persists. Messages start
            // in their order, so one waiting for the oversized message ahead
            // of it holds back the ones after it, while those already running
            // go on. Results keep the input order whatever order they finish in.
            var oversizedIndexInFlight: Int?

            func startMessages() {
                while nextIndex < gmailMessages.count, running < maxConcurrent {
                    let index = nextIndex
                    let message = gmailMessages[index]
                    let isOversized = Self.textBodyByteCount(of: message) > SyncConfig.oversizedPreparationBodyBytes
                    if isOversized {
                        guard oversizedIndexInFlight == nil else { return }
                        oversizedIndexInFlight = index
                    }
                    group.addTask { [self] in
                        (index, try await self.prepareMessage(
                            message,
                            myAliases: myAliases,
                            sendAsAliases: sendAsAliases
                        ))
                    }
                    running += 1
                    nextIndex += 1
                }
            }

            startMessages()
            while let (index, prepared) = try await group.next() {
                results[index] = prepared
                running -= 1
                if index == oversizedIndexInFlight {
                    oversizedIndexInFlight = nil
                }
                startMessages()
            }

            return results.compactMap { $0 }
        }
    }

    /// The bytes of the message's text and HTML body parts, as Gmail sizes
    /// them, inline or fetched later by attachment ID. Attachments do not
    /// count: their bytes are never derived from.
    nonisolated static func textBodyByteCount(of message: GmailMessage) -> Int {
        func count(_ part: MessagePart) -> Int {
            let mimeType = part.mimeType?.lowercased() ?? ""
            let isTextBody = (mimeType.hasPrefix("text/html") || mimeType.hasPrefix("text/plain")) &&
                (part.filename ?? "").isEmpty
            let own = isTextBody ? (part.body?.size ?? 0) : 0
            return (part.parts ?? []).reduce(own) { $0 + count($1) }
        }
        return message.payload.map(count) ?? 0
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
        case .excludedMailbox(let id, let label, _):
            let removedCleanly = await deleteExistingMessageIfPresent(
                id: id,
                modificationTransaction: modificationTransaction,
                remoteCommittedSendMutation: remoteCommittedSendMutation,
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
            case .bodyWriteFailed(let failure):
                return try Self.dispositionAfterBodyWriteFailure(failure)
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
            } catch let bodyWriteFailure as MessageBodyWriteFailure {
                return try Self.dispositionAfterBodyWriteFailure(bodyWriteFailure)
            } catch CoreDataError.entityCreationFailed(let entity) {
                // Model/schema mismatch: every message in the run fails the
                // same way, so this is run-fatal, not a per-message verdict.
                throw CoreDataError.entityCreationFailed(entity)
            } catch let error where StorageErrorClassifier.isOutOfSpace(error) {
                // A full disk can surface from Core Data instead of the body write: conversation
                // routing saves its own shell context. It proves nothing about this message, so
                // it ends the run like a full-disk body write (`dispositionAfterBodyWriteFailure`)
                // rather than spending the escape hatch on a per-message `.failed`.
                throw SyncResourceAbort.insufficientStorage
            } catch {
                Log.error("Failed to create message \(processedMessage.id): \(error)", category: .sync)
                return .failed
            }
        }
    }
}

extension MessagePersister {
    static let excludedMailboxLabelIDs: Set<String> = ["SPAM", "DRAFT", "TRASH"]

    /// The verdict for a message whose body could not be written. Nothing was persisted for it.
    ///
    /// - A closed boundary is account teardown, so it throws cancellation, which is never a
    ///   per-message verdict.
    /// - A full volume throws `SyncResourceAbort.insufficientStorage`: a run-level abort, like an
    ///   account-scoped API error. No bucket, no further requests, nothing commits. As `.failed` it
    ///   would freeze the cursor correctly but spend the escape hatch on every message in the
    ///   backlog, and the next write would fail the same way.
    /// - Any other write failure is `.failed`: the cursor holds and the re-scan retries it.
    static func dispositionAfterBodyWriteFailure(
        _ failure: MessageBodyWriteFailure
    ) throws -> MessagePersistDisposition {
        switch failure {
        case .boundaryClosed:
            throw CancellationError()
        case .outOfSpace:
            throw SyncResourceAbort.insufficientStorage
        case .ioError:
            return .failed
        }
    }
}
