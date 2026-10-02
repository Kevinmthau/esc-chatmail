import CoreData
import Foundation

/// Rewrites persisted `Message.chatPreviewText` in ID-ordered batches. The
/// caller owns the account lease, pending-send serialization, save, and durable
/// cursor checkpoint. Messages in conversations with a pending
/// `OutboundSendMutationRecord` are deferred, never rewritten; once the main
/// scan drains, only those deferred rows are retried.
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

    struct Batch: Sendable {
        enum Phase: Sendable {
            /// One ID-ordered slice of the full scan.
            case mainScan
            /// One ID-ordered slice of the persisted deferred list.
            case deferredRetry
        }

        var phase: Phase = .mainScan
        /// Main scan: the scan cursor. Deferred retry: the last deferred ID
        /// this batch examined, which is the caller's in-run retry cursor.
        var lastMessageID: String?
        var changedMessageIDs: Set<String> = []
        /// Main scan: no rows remain after the cursor. Deferred retry: this
        /// batch examined the last deferred ID.
        var didDrain = false
        /// Rows skipped because their conversation still has a pending
        /// `OutboundSendMutationRecord`: newly deferred by a main-scan batch,
        /// or still deferred after a retry batch.
        var deferredMessageIDs: [String] = []
        /// Deferred retry only: the deferred IDs this batch examined. Each one
        /// leaves the deferred list unless it is in `deferredMessageIDs` again.
        var retriedMessageIDs: [String] = []
    }

    /// One serialized checkpoint keeps the scan cursor and the deferred rows
    /// together if the process exits between batches.
    ///
    /// Deferred rows are remembered by message ID once the main scan has
    /// passed them, and the scan is marked complete when it drains. Earlier
    /// builds remembered only the first deferred ID and restarted the whole
    /// scan from it whenever a pass drained; a retained failed or
    /// delivery-unknown send can live indefinitely, so those builds re-derived
    /// every later row on every sync completion, holding the cleanup-sensitive
    /// gate that optimistic sends wait on.
    struct Checkpoint: Codable, Sendable, Equatable {
        var afterMessageID: String?
        /// Legacy: written only by builds that predate `deferredMessageIDs`.
        /// A checkpoint decoded with it set restarts the scan from it once, at
        /// drain, to learn which rows that build skipped; new scans never set it.
        var firstDeferredMessageID: String?
        /// Lower bound for the scan; set only by a legacy restart.
        var resumeAtMessageID: String?
        /// Sorted, de-duplicated IDs of rows the main scan skipped for a
        /// pending send and has not yet re-derived.
        var deferredMessageIDs: [String] = []
        var isMainScanComplete = false

        init(
            afterMessageID: String? = nil,
            firstDeferredMessageID: String? = nil,
            resumeAtMessageID: String? = nil,
            deferredMessageIDs: [String] = [],
            isMainScanComplete: Bool = false
        ) {
            self.afterMessageID = afterMessageID
            self.firstDeferredMessageID = firstDeferredMessageID
            self.resumeAtMessageID = resumeAtMessageID
            self.deferredMessageIDs = deferredMessageIDs
            self.isMainScanComplete = isMainScanComplete
        }

        /// Tolerates the pre-`deferredMessageIDs` encoding: every key is
        /// optional, so an old checkpoint decodes with an empty deferred list
        /// and an incomplete main scan instead of failing and restarting the
        /// pass from scratch.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            afterMessageID = try container.decodeIfPresent(String.self, forKey: .afterMessageID)
            firstDeferredMessageID = try container.decodeIfPresent(String.self, forKey: .firstDeferredMessageID)
            resumeAtMessageID = try container.decodeIfPresent(String.self, forKey: .resumeAtMessageID)
            deferredMessageIDs = try container.decodeIfPresent([String].self, forKey: .deferredMessageIDs) ?? []
            isMainScanComplete = try container.decodeIfPresent(Bool.self, forKey: .isMainScanComplete) ?? false
        }

        static func decode(_ value: String?) -> Self {
            value.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        }

        var encoded: String? {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }

        /// The pass may latch its completion flag: the scan drained and every
        /// deferred row has since been re-derived (or no longer exists).
        var isComplete: Bool {
            isMainScanComplete && deferredMessageIDs.isEmpty
        }

        /// The checkpoint to persist after `batch` saved successfully.
        func advanced(by batch: Batch) -> Self {
            var next = self
            switch batch.phase {
            case .mainScan:
                next.afterMessageID = batch.lastMessageID
                next.deferredMessageIDs = Self.normalized(deferredMessageIDs + batch.deferredMessageIDs)
                guard batch.didDrain else { return next }
                if let legacyBoundary = firstDeferredMessageID {
                    // A pre-upgrade scan skipped rows from this ID on without
                    // recording which. Rescan that range once; this scan
                    // records what it skips, so the restart cannot repeat.
                    next = Self(
                        resumeAtMessageID: legacyBoundary,
                        deferredMessageIDs: next.deferredMessageIDs
                    )
                } else {
                    next.afterMessageID = nil
                    next.resumeAtMessageID = nil
                    next.isMainScanComplete = true
                }
            case .deferredRetry:
                let retried = Set(batch.retriedMessageIDs)
                next.deferredMessageIDs = Self.normalized(
                    deferredMessageIDs.filter { !retried.contains($0) } + batch.deferredMessageIDs
                )
            }
            return next
        }

        private static func normalized(_ messageIDs: [String]) -> [String] {
            Array(Set(messageIDs)).sorted()
        }
    }

    let htmlContentHandler: HTMLContentHandler
    var pass: Pass = .receivedHTMLRederivation

    /// The next batch for `checkpoint`: a main-scan slice until the scan
    /// completes, then a slice of the deferred list after `retryAfter` (the
    /// caller's in-run retry cursor, never persisted, so every run re-checks
    /// the whole deferred list once).
    func prepareNextBatch(
        in context: NSManagedObjectContext,
        checkpoint: Checkpoint,
        retryAfter retryCursor: String?,
        limit: Int = 100
    ) async throws -> Batch {
        if checkpoint.isMainScanComplete {
            return try await prepareDeferredRetryBatch(
                in: context,
                deferredMessageIDs: checkpoint.deferredMessageIDs,
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

    /// Re-derives deferred rows whose conversation no longer has a pending
    /// `OutboundSendMutationRecord`. Rows still pending stay deferred without
    /// a disk read; rows that no longer exist or no longer match the pass
    /// leave the list. The pending set is read inside this `perform`, which
    /// the caller runs under the cleanup-sensitive gate, so a send that lands
    /// first is seen and one that lands after waits for this batch to save.
    ///
    /// `limit` bounds the rows this batch derives, not the rows it examines.
    /// A retained failed or delivery-unknown send can defer a whole long
    /// conversation indefinitely, and every sync completion re-runs this
    /// sweep; counting still-pending rows against `limit` turned that into
    /// one gate hold and one checkpoint rewrite per `limit` deferred rows on
    /// every sync, none of which changed anything. Still-pending rows cost
    /// only an ID-chunked fetch (`lookupChunkSize` IDs per `IN` predicate),
    /// so a sweep that finds nothing to derive is a single short hold.
    func prepareDeferredRetryBatch(
        in context: NSManagedObjectContext,
        deferredMessageIDs: [String],
        after retryCursor: String?,
        limit: Int = 100,
        lookupChunkSize: Int = 500
    ) async throws -> Batch {
        let remaining = deferredMessageIDs.sorted().filter { id in retryCursor.map { id > $0 } ?? true }
        guard !remaining.isEmpty else {
            return Batch(phase: .deferredRetry, lastMessageID: retryCursor, didDrain: true)
        }
        let derivationLimit = max(1, limit)
        let chunkSize = max(1, lookupChunkSize)
        return try await context.perform {
            try Task.checkCancellation()
            let pendingConversationIDs = try Self.pendingConversationIDs(in: context)
            var batch = Batch(phase: .deferredRetry, lastMessageID: retryCursor)
            var derivedCount = 0
            var chunkStart = remaining.startIndex
            while chunkStart < remaining.endIndex, derivedCount < derivationLimit {
                try Task.checkCancellation()
                let chunk = Array(remaining[chunkStart..<min(chunkStart + chunkSize, remaining.endIndex)])
                let request = Message.fetchRequest()
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    Self.basePredicate(for: pass),
                    NSPredicate(format: "id IN %@", chunk as NSArray)
                ])
                request.relationshipKeyPathsForPrefetching = ["conversation"]
                // Sorted here rather than by the store, so the stop point
                // below and the `<=` filter agree on one ordering.
                let messages = try context.fetch(request).sorted { $0.id < $1.id }
                // The last ID this chunk examined. Stopping at the derivation
                // limit examines the chunk only through the row that hit it;
                // later IDs stay untouched for the next batch.
                var examinedThrough = chunk[chunk.count - 1]
                for message in messages {
                    try Task.checkCancellation()
                    if let conversationID = message.conversation?.id,
                       pendingConversationIDs.contains(conversationID) {
                        batch.deferredMessageIDs.append(message.id)
                        continue
                    }
                    applyDerivedPreview(to: message, recordingChangeIn: &batch)
                    derivedCount += 1
                    if derivedCount >= derivationLimit {
                        examinedThrough = message.id
                        break
                    }
                }
                // IDs the fetch did not return no longer exist or no longer
                // match the pass; listing them as retried drops them.
                batch.retriedMessageIDs.append(contentsOf: chunk.filter { $0 <= examinedThrough })
                batch.lastMessageID = examinedThrough
                chunkStart += chunk.count
            }
            batch.didDrain = batch.lastMessageID == remaining.last
            return batch
        }
    }

    func prepareBatch(
        in context: NSManagedObjectContext,
        after messageID: String?,
        startingAt firstMessageID: String? = nil,
        limit: Int = 100
    ) async throws -> Batch {
        try await context.perform {
            try Task.checkCancellation()
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
            for message in messages {
                try Task.checkCancellation()
                if let conversationID = message.conversation?.id,
                   pendingConversationIDs.contains(conversationID) {
                    // Retained failed sends can live indefinitely. Remember the
                    // row for a targeted retry without starving later
                    // unrelated messages or rescanning past it.
                    batch.deferredMessageIDs.append(message.id)
                    batch.lastMessageID = message.id
                    continue
                }
                applyDerivedPreview(to: message, recordingChangeIn: &batch)
                batch.lastMessageID = message.id
            }
            return batch
        }
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
