import CoreData
import Foundation
import os

/// Rewrites persisted `Message.chatPreviewText` in ID-ordered batches. The
/// caller owns the account lease, pending-send serialization, save, and durable
/// cursor checkpoint. Messages in conversations with a pending
/// `OutboundSendMutationRecord` are deferred, never rewritten; once the main
/// scan drains, only those deferred conversations are retried.
///
/// Cancelling the calling task stops a batch at its next row
/// (`performBatch`): the batch throws `CancellationError`, and the caller
/// discards it and rolls the context back, as for any other thrown batch.
///
/// Split across:
/// - `ChatPreviewRepair.swift` - passes, batches, and preview derivation
/// - `ChatPreviewRepair+Checkpoint.swift` - the durable checkpoint and its
///   deferred-conversation list, including legacy checkpoint decoding
/// - `ChatPreviewRepair+RetryAnchors.swift` - the deferred conversations
///   that hash-changing conversation maintenance must leave in place
struct ChatPreviewRepair {
    enum Pass: Sendable {
        /// Re-derives received previews from local HTML after a derivation
        /// change (keyed by `CacheVersioning.chatPreviewDerivationVersion`).
        /// Scans every received row, not just `bodyStorageURI` ones: recovery
        /// stores HTML under the message ID alone, and those rows must not be
        /// stranded on an old derivation. Rows with no local HTML derive
        /// nothing and keep their saved preview.
        case receivedHTMLRederivation
        /// Fills blank previews with exactly the text the bubble loader's
        /// compatibility path already shows, from local sources only, so those
        /// rows stop re-deriving on every load. Rows whose bubble depends on
        /// something a stored preview would change are left blank; see
        /// `backfilledPreview`.
        case blankPreviewBackfill
    }

    /// The deferred-retry sweep's position within one run. Deliberately never
    /// persisted (see `ConversationLaunchRepairCoordinator.runChatPreviewPass`).
    struct RetryCursor: Sendable, Equatable {
        /// `DeferredConversation.sortKey` of the conversation the sweep is in,
        /// or has just passed.
        var conversationKey: String
        /// The last row re-derived in that conversation, or nil once the
        /// sweep is done with it (finished, still pending, or gone).
        var afterMessageID: String?
    }

    struct Batch: Sendable {
        enum Phase: Sendable {
            /// One ID-ordered slice of the full scan.
            case mainScan
            /// One slice of the deferred-conversation sweep.
            case deferredRetry
            /// Maps a checkpoint's legacy per-message deferred IDs to their
            /// conversations; derives nothing.
            case legacyDeferredMigration
        }

        var phase: Phase = .mainScan
        /// Main scan only: the scan cursor.
        var lastMessageID: String?
        var changedMessageIDs: Set<String> = []
        /// Main scan: no rows remain after the cursor. Deferred retry: this
        /// batch is done with the last deferred conversation.
        var didDrain = false
        /// Main scan: conversations whose rows this batch skipped for a
        /// pending `OutboundSendMutationRecord`. Legacy migration: the current
        /// conversations of the legacy deferred rows.
        var deferredConversations: [DeferredConversation] = []
        /// Deferred retry only: conversations this batch finished, whose rows
        /// are all re-derived (or that have no rows left to find). Each leaves
        /// the deferred list; still-pending conversations are never listed.
        var retriedConversationIDs: [UUID] = []
        /// Deferred retry only: where the next retry batch of this run resumes.
        var retryCursor: RetryCursor?
    }

    let htmlContentHandler: HTMLContentHandler
    var pass: Pass = .receivedHTMLRederivation
#if DEBUG
    /// Test seam: runs on the context's queue after each row a batch derives,
    /// so a test can land a cancellation between two rows of one batch.
    var didDeriveRow: (@Sendable (_ messageID: String) -> Void)?
#endif

    /// The calling task's cancellation, in a form a `context.perform` block
    /// can read. That block runs on the context's queue with no current Swift
    /// task, so in there `Task.isCancelled` is always false and
    /// `Task.checkCancellation()` never throws, however long ago the caller
    /// was cancelled (a closure that evaluates `Task.isCancelled` inside the
    /// block is equally blind). `performBatch` sets this from the calling
    /// task's cancellation handler instead, and the batch loops read it.
    private final class BatchCancellation: Sendable {
        private let isCancelled = OSAllocatedUnfairLock(initialState: false)

        func cancel() {
            isCancelled.withLock { $0 = true }
        }

        func check() throws {
            if isCancelled.withLock({ $0 }) {
                throw CancellationError()
            }
        }
    }

    /// Runs one batch on `context`'s queue and stops it when the calling task
    /// is cancelled. `body` does not start for an already-cancelled caller,
    /// and its loops call `BatchCancellation.check()` before each row (each
    /// lookup chunk, for the legacy migration), so a cancellation that lands
    /// mid-batch throws at the next row instead of deriving the rest of the
    /// batch under the caller's lease and the cleanup-sensitive gate
    /// optimistic sends wait on. Rows the batch had already rewritten are
    /// still unsaved in `context`; the caller rolls them back with the thrown
    /// batch.
    private static func performBatch<Value>(
        in context: NSManagedObjectContext,
        _ body: @escaping (BatchCancellation) throws -> Value
    ) async throws -> Value {
        let cancellation = BatchCancellation()
        return try await withTaskCancellationHandler {
            try await context.perform {
                try cancellation.check()
                return try body(cancellation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// The next batch for `checkpoint`: a legacy-list migration first if the
    /// checkpoint still carries per-message deferred IDs, then a main-scan
    /// slice until the scan completes, then a slice of the deferred sweep
    /// after `retryCursor` (the caller's in-run retry cursor, never persisted,
    /// so every run re-checks the whole deferred list once).
    func prepareNextBatch(
        in context: NSManagedObjectContext,
        checkpoint: Checkpoint,
        retryAfter retryCursor: RetryCursor?,
        limit: Int = 100
    ) async throws -> Batch {
        if !checkpoint.legacyDeferredMessageIDs.isEmpty {
            return try await prepareLegacyDeferredMigrationBatch(
                in: context,
                legacyDeferredMessageIDs: checkpoint.legacyDeferredMessageIDs
            )
        }
        if checkpoint.isMainScanComplete {
            return try await prepareDeferredRetryBatch(
                in: context,
                deferredConversations: checkpoint.deferredConversations,
                after: retryCursor,
                limit: limit
            )
        }
        return try await prepareBatch(
            in: context,
            after: checkpoint.afterMessageID,
            startingAt: checkpoint.resumeAtMessageID,
            limit: limit
        )
    }

    /// Converts the per-message deferred list an earlier build persisted into
    /// deferred conversations, so the checkpoint stops carrying one ID per
    /// row. Each legacy row is located by ID and its current conversation is
    /// deferred, which over-covers (the whole conversation is retried, and
    /// re-deriving an already-current row changes nothing) but never drops a
    /// row that still needs deriving. Rows that no longer exist or no longer
    /// match the pass leave the list, exactly as the old per-row retry dropped
    /// them. A row with no conversation is dropped too: the legacy scan
    /// deferred only rows of a pending conversation, and with no conversation
    /// there is nothing a retry could find it by.
    func prepareLegacyDeferredMigrationBatch(
        in context: NSManagedObjectContext,
        legacyDeferredMessageIDs: [String],
        lookupChunkSize: Int = 500
    ) async throws -> Batch {
        let ids = Array(Set(legacyDeferredMessageIDs)).sorted()
        let chunkSize = max(1, lookupChunkSize)
        return try await Self.performBatch(in: context) { cancellation in
            var batch = Batch(phase: .legacyDeferredMigration)
            var seen = Set<UUID>()
            var chunkStart = ids.startIndex
            while chunkStart < ids.endIndex {
                try cancellation.check()
                let chunk = Array(ids[chunkStart..<min(chunkStart + chunkSize, ids.endIndex)])
                let request = Message.fetchRequest()
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    Self.basePredicate(for: pass),
                    NSPredicate(format: "id IN %@", chunk as NSArray)
                ])
                request.relationshipKeyPathsForPrefetching = ["conversation"]
                for message in try context.fetch(request) {
                    guard let conversation = message.conversation,
                          seen.insert(conversation.id).inserted else { continue }
                    batch.deferredConversations.append(DeferredConversation(conversation))
                }
                chunkStart += chunk.count
            }
            return batch
        }
    }

    /// Re-derives the rows of deferred conversations that no longer have a
    /// pending `OutboundSendMutationRecord`. A still-pending conversation
    /// stays deferred without a fetch, let alone a disk read. The pending set
    /// is read inside this `perform`, which the caller runs under the
    /// cleanup-sensitive gate, so a send that lands first is seen and one that
    /// lands after waits for this batch to save.
    ///
    /// Deferral is per conversation, not per row, so the persisted list is
    /// bounded by the conversations that had a retained send when the scan
    /// reached them rather than by their row counts. The retry therefore
    /// re-derives the conversation's rows as they are now, which also covers
    /// rows that arrived after the scan (re-deriving a current row changes
    /// nothing). A deferred conversation can stop existing only after its
    /// record cleared, since both duplicate-merge passes skip pending
    /// conversations; a merge moves its rows into a survivor with the same
    /// participant hash, so a gone conversation is retried through every
    /// conversation with its recorded hash, unless one of those is pending.
    /// Rows sync re-homes out of a deferred conversation get a freshly
    /// processed preview in that same save. The maintenance passes that move
    /// rows to a different hash (the participant-set split migration and the
    /// hash-correcting merge, `DataCleanupService+Migration`) would take them
    /// out of reach, and the main scan has already passed them, so those
    /// passes skip every conversation this sweep still has to visit
    /// (`DeferredRetryAnchors`) and move its rows only after it leaves the
    /// list; the split keeps its flag clear until then.
    ///
    /// HONEST SCOPE: a blank-preview row that sync re-homes with no preview at
    /// all stays blank, which the bubble loader's compatibility path still
    /// renders. The per-row list this replaced followed it, at the cost of
    /// growing with every deferred row.
    ///
    /// `limit` bounds the rows this batch derives, not the conversations it
    /// examines: a retained failed or delivery-unknown send can defer a
    /// conversation indefinitely, and every sync completion re-runs this
    /// sweep, so a sweep that finds nothing to derive is a single short hold.
    func prepareDeferredRetryBatch(
        in context: NSManagedObjectContext,
        deferredConversations: [DeferredConversation],
        after retryCursor: RetryCursor?,
        limit: Int = 100
    ) async throws -> Batch {
        let remaining = deferredConversations
            .sorted { $0.sortKey < $1.sortKey }
            .filter { entry in
                guard let retryCursor else { return true }
                return entry.sortKey > retryCursor.conversationKey ||
                    (entry.sortKey == retryCursor.conversationKey && retryCursor.afterMessageID != nil)
            }
        guard let lastKey = remaining.last?.sortKey else {
            return Batch(phase: .deferredRetry, didDrain: true, retryCursor: retryCursor)
        }
        let derivationLimit = max(1, limit)
        return try await Self.performBatch(in: context) { cancellation in
            let pendingConversationIDs = try Self.pendingConversationIDs(in: context)
            var batch = Batch(phase: .deferredRetry, retryCursor: retryCursor)
            var derivedCount = 0
            for entry in remaining {
                guard derivedCount < derivationLimit else { break }
                try cancellation.check()
                let resumeAfter = retryCursor?.conversationKey == entry.sortKey ? retryCursor?.afterMessageID : nil
                let scope = try Self.retryScope(
                    for: entry,
                    pendingConversationIDs: pendingConversationIDs,
                    in: context
                )
                let rowScope: NSPredicate
                switch scope {
                case .pending:
                    // Stays deferred; later conversations are still examined.
                    batch.retryCursor = RetryCursor(conversationKey: entry.sortKey)
                    continue
                case .gone:
                    batch.retriedConversationIDs.append(entry.id)
                    batch.retryCursor = RetryCursor(conversationKey: entry.sortKey)
                    continue
                case .rows(let predicate):
                    rowScope = predicate
                }
                var predicates = [Self.basePredicate(for: pass), rowScope]
                if let resumeAfter {
                    predicates.append(NSPredicate(format: "id > %@", resumeAfter))
                }
                let budget = derivationLimit - derivedCount
                let request = Message.fetchRequest()
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
                request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
                request.fetchLimit = budget
                request.fetchBatchSize = budget
                let messages = try context.fetch(request)
                for message in messages {
                    try cancellation.check()
                    applyDerivedPreview(to: message, recordingChangeIn: &batch)
                }
                derivedCount += messages.count
                if messages.count < budget {
                    batch.retriedConversationIDs.append(entry.id)
                    batch.retryCursor = RetryCursor(conversationKey: entry.sortKey)
                } else {
                    // The budget ran out inside this conversation; the next
                    // batch resumes after the last row derived here.
                    batch.retryCursor = RetryCursor(
                        conversationKey: entry.sortKey,
                        afterMessageID: messages.last?.id
                    )
                }
            }
            batch.didDrain = batch.retryCursor == RetryCursor(conversationKey: lastKey)
            return batch
        }
    }

    func prepareBatch(
        in context: NSManagedObjectContext,
        after messageID: String?,
        startingAt firstMessageID: String? = nil,
        limit: Int = 100
    ) async throws -> Batch {
        try await Self.performBatch(in: context) { cancellation in
            let pendingConversationIDs = try Self.pendingConversationIDs(in: context)
            let request = Message.fetchRequest()
            var predicates = [Self.basePredicate(for: pass)]
            if let messageID {
                predicates.append(NSPredicate(format: "id > %@", messageID))
            }
            if let firstMessageID {
                predicates.append(NSPredicate(format: "id >= %@", firstMessageID))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            request.fetchLimit = max(1, limit)
            request.fetchBatchSize = max(1, limit)
            request.relationshipKeyPathsForPrefetching = ["conversation"]
            let messages = try context.fetch(request)
            var batch = Batch(lastMessageID: messageID, didDrain: messages.isEmpty)
            var deferredIDs = Set<UUID>()
            for message in messages {
                try cancellation.check()
                if let conversation = message.conversation,
                   pendingConversationIDs.contains(conversation.id) {
                    // Retained failed sends can live indefinitely. Remember the
                    // conversation for a targeted retry without starving later
                    // unrelated messages or rescanning past it.
                    if deferredIDs.insert(conversation.id).inserted {
                        batch.deferredConversations.append(DeferredConversation(conversation))
                    }
                    batch.lastMessageID = message.id
                    continue
                }
                applyDerivedPreview(to: message, recordingChangeIn: &batch)
                batch.lastMessageID = message.id
            }
            return batch
        }
    }

    private enum RetryScope {
        /// The conversation (or, once gone, a conversation sharing its hash)
        /// still has a pending send: leave the entry deferred.
        case pending
        /// Nothing left to find: the entry leaves the list.
        case gone
        /// The rows to re-derive.
        case rows(NSPredicate)
    }

    private static func retryScope(
        for entry: DeferredConversation,
        pendingConversationIDs: Set<UUID>,
        in context: NSManagedObjectContext
    ) throws -> RetryScope {
        // A record can outlive its conversation, so pending is checked first.
        guard !pendingConversationIDs.contains(entry.id) else { return .pending }
        let existing = Conversation.fetchRequest()
        existing.predicate = NSPredicate(format: "id == %@", entry.id as CVarArg)
        if try context.count(for: existing) > 0 {
            return .rows(NSPredicate(format: "conversation.id == %@", entry.id as CVarArg))
        }
        guard let participantHash = entry.participantHash else { return .gone }
        let survivors = NSFetchRequest<NSDictionary>(entityName: "Conversation")
        survivors.resultType = .dictionaryResultType
        survivors.propertiesToFetch = ["id"]
        survivors.predicate = NSPredicate(format: "participantHash == %@", participantHash)
        let survivorIDs = try context.fetch(survivors).compactMap { $0["id"] as? UUID }
        guard !survivorIDs.isEmpty else { return .gone }
        guard pendingConversationIDs.isDisjoint(with: survivorIDs) else { return .pending }
        return .rows(NSPredicate(format: "conversation.participantHash == %@", participantHash))
    }

    private static func pendingConversationIDs(in context: NSManagedObjectContext) throws -> Set<UUID> {
        Set(
            try context.fetch(OutboundSendMutationRecord.fetchRequest())
                .compactMap(\.conversationId)
        )
    }

    private func applyDerivedPreview(to message: Message, recordingChangeIn batch: inout Batch) {
        if let preview = derivedPreview(for: message),
           !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           preview != message.chatPreviewText {
            message.chatPreviewText = preview
            batch.changedMessageIDs.insert(message.id)
        }
        // Missing files and empty derivations preserve the existing
        // preview; a later source recovery re-enters the ingest path.
#if DEBUG
        didDeriveRow?(message.id)
#endif
    }

    private static func basePredicate(for pass: Pass) -> NSPredicate {
        switch pass {
        case .receivedHTMLRederivation:
            return NSPredicate(format: "isFromMe == NO")
        case .blankPreviewBackfill:
            // Whitespace-only counts as blank, matching the loader's `nonEmptyText`.
            return NSPredicate(
                format: "chatPreviewText == nil OR chatPreviewText == '' OR chatPreviewText MATCHES %@",
                #"^\s+$"#
            )
        }
    }

    private func derivedPreview(for message: Message) -> String? {
        switch pass {
        case .receivedHTMLRederivation:
            let html = htmlContentHandler.loadHTML(for: message.id) ??
                message.bodyStorageURI.flatMap(StorageURIResolver.resolve)
                    .flatMap { htmlContentHandler.loadHTML(from: $0) }
            return MessageProcessor.deriveHTMLChatPreview(from: html)
        case .blankPreviewBackfill:
            return Self.backfilledPreview(
                messageId: message.id,
                isFromMe: message.isFromMe,
                subject: message.subject,
                senderEmail: message.senderEmail,
                bodyStorageURI: message.bodyStorageURI,
                bodyText: message.bodyText,
                handler: htmlContentHandler
            )
        }
    }

    /// The text `MessageBubbleLoader.loadContent` shows for a blank-preview row,
    /// or nil when storing a preview would change that bubble. Built from the
    /// loader's own shared steps so the two cannot drift.
    static func backfilledPreview(
        messageId: String,
        isFromMe: Bool,
        subject: String?,
        senderEmail: String?,
        bodyStorageURI: String?,
        bodyText: String?,
        handler: HTMLContentHandler
    ) -> String? {
        // A blank preview makes forwarded bubbles parse their lead-in from the
        // body; a stored preview would replace that lead-in.
        guard !MessagePreviewText.isForwardedSubject(subject) else { return nil }
        let stored = MessageBubbleContentSource.processMessage(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            handler: handler
        )
        let storedHTMLText = stored.plainText
        guard isFromMe else {
            // Received rows stay with the loader whenever it could still
            // replace this text with HTML recovered over the network: with no
            // local text at all, for trusted transactional senders, and when
            // the body reads like a newsletter's HTML-only fallback. Mirrors
            // the recovery conditions in `loadCompatibilityContent`.
            guard let storedHTMLText,
                  !MessageDisplayPolicy.isTrustedTransactionalSender(senderEmail) else {
                return nil
            }
            // The loader's check also falls back to `snippet`, but only when
            // there is no local text at all — which the guard above already
            // returned to the loader.
            let recoversNewsletterFallback = !stored.hasRichContent &&
                NewsletterFallbackText.looksLikeFallbackText(bodyText ?? storedHTMLText)
            return recoversNewsletterFallback ? nil : storedHTMLText
        }
        // Outgoing rows never recover over the network, so this is fully
        // local: stored HTML text, else the body-text fallback, unless the
        // legacy outgoing body is richer. The richer-body comparison stays
        // here even though the bubble loader no longer runs it: a device
        // upgrading straight from a pre-backfill build still needs this pass
        // to migrate those rows, and nothing else can recover the fuller
        // authored text afterwards.
        let loadedText = storedHTMLText ?? bodyText.flatMap {
            MessageBubbleContentSource.bodyTextFallback(from: $0).mainText
        }
        return LegacyOutgoingBodyTextFallback.preferredBodyText(fromBody: bodyText, over: loadedText) ?? loadedText
    }
}
