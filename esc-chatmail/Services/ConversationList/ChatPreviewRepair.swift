import CoreData
import Foundation

/// Re-derives only received, HTML-backed previews. The caller owns the account
/// lease, pending-send serialization, save, and durable cursor checkpoint.
struct ChatPreviewRepair {
    struct Batch: Sendable {
        var lastMessageID: String?
        var changedMessageIDs: Set<String> = []
        var didDrain = false
        var deferredForPendingSend = false
    }

    let htmlContentHandler: HTMLContentHandler

    func prepareBatch(
        in context: NSManagedObjectContext,
        after messageID: String?,
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
                    // Do not checkpoint past this row: its optimistic-send
                    // protection must be re-evaluated after reconciliation.
                    batch.deferredForPendingSend = true
                    break
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
