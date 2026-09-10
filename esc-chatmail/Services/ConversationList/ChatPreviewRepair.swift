import CoreData
import Foundation

/// Re-derives only received, HTML-backed previews. The caller owns the account
/// lease, pending-send serialization, save, and durable cursor checkpoint.
struct ChatPreviewRepair {
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
            var predicates = [NSPredicate(format: "isFromMe == NO AND bodyStorageURI != nil")]
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
                let html = htmlContentHandler.loadHTML(for: message.id) ??
                    message.bodyStorageURI.flatMap(StorageURIResolver.resolve)
                        .flatMap { htmlContentHandler.loadHTML(from: $0) }
                if let preview = MessageProcessor.deriveHTMLChatPreview(from: html),
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
}
