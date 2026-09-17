import CoreData
import Foundation

/// Rewrites persisted `Message.chatPreviewText` in ID-ordered batches. The
/// caller owns the account lease, pending-send serialization, save, and durable
/// cursor checkpoint. Messages in conversations with a pending
/// `OutboundSendMutationRecord` are deferred, never rewritten.
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
        var lastMessageID: String?
        var changedMessageIDs: Set<String> = []
        var didDrain = false
        var firstDeferredMessageID: String?
    }

    /// One serialized checkpoint keeps the scan cursor and deferred retry
    /// boundary together if the process exits between batches.
    struct Checkpoint: Codable, Sendable {
        var afterMessageID: String?
        var firstDeferredMessageID: String?
        var resumeAtMessageID: String?

        static func decode(_ value: String?) -> Self {
            value.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        }

        var encoded: String? {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    let htmlContentHandler: HTMLContentHandler
    var pass: Pass = .receivedHTMLRederivation

    func prepareBatch(
        in context: NSManagedObjectContext,
        after messageID: String?,
        startingAt firstMessageID: String? = nil,
        limit: Int = 100
    ) async throws -> Batch {
        try await context.perform {
            try Task.checkCancellation()
            let pendingConversationIDs = Set(
                try context.fetch(OutboundSendMutationRecord.fetchRequest())
                    .compactMap(\.conversationId)
            )
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
                    // Retained failed sends can live indefinitely. Remember a
                    // retry boundary without starving later unrelated messages.
                    if batch.firstDeferredMessageID == nil { batch.firstDeferredMessageID = message.id }
                    batch.lastMessageID = message.id
                    continue
                }
                if let preview = derivedPreview(for: message),
                   !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   preview != message.chatPreviewText {
                    message.chatPreviewText = preview
                    batch.changedMessageIDs.insert(message.id)
                }
                // Missing files and empty derivations preserve the existing
                // preview; a later source recovery re-enters the ingest path.
                batch.lastMessageID = message.id
            }
            return batch
        }
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
        // Outgoing rows never recover over the network, so the loader's result
        // is fully local: stored HTML text, else the body-text fallback, unless
        // the legacy outgoing body is richer.
        let loadedText = storedHTMLText ?? bodyText.flatMap {
            MessageBubbleContentSource.bodyTextFallback(from: $0).mainText
        }
        return LegacyOutgoingBodyTextFallback.preferredBodyText(fromBody: bodyText, over: loadedText) ?? loadedText
    }
}
