import CoreData
import Foundation

extension ChatPreviewRepair {
    /// Where the chat-preview passes' deferred retries will look for rows, so
    /// conversation maintenance that moves rows across participant hashes can
    /// leave those rows in place until the retry has re-derived them.
    ///
    /// Deferral is per conversation (`DeferredConversation`): the retry finds
    /// rows by the deferred conversation's ID while it exists, and through its
    /// recorded participant hash once a same-hash duplicate merge has deleted
    /// it (`prepareDeferredRetryBatch`). A move that changes a row's hash, the
    /// participant-set split or the hash-correcting merge, takes the row out
    /// of both scopes; the retry then re-derives only what stayed behind and
    /// drops the entry, and the moved row keeps the previous derivation for
    /// good, since the main scan has already passed it and old mail is not
    /// re-ingested. Those passes therefore treat an anchored conversation like
    /// a pending send's: skip it, and retry after the entry leaves the list.
    ///
    /// The cost is a delay, never a lost move: an entry leaves the list on
    /// the first retry sweep after its conversation stops being pending (every
    /// launch and sync completion runs one), and a split held back meanwhile
    /// keeps its flag clear. That includes a replacement account inheriting
    /// the checkpoint (see `ConversationLaunchRepairCoordinator`): the previous
    /// account's entries anchor at most its same-hash conversations, and only
    /// until that first sweep drops them.
    struct DeferredRetryAnchors: Sendable, Equatable {
        /// Deferred conversations that still exist.
        var conversationIDs: Set<UUID> = []
        /// Recorded hashes of deferred conversations that no longer exist.
        var participantHashes: Set<String> = []

        /// Whether a deferred retry would look for `conversation`'s rows.
        func anchors(_ conversation: Conversation) -> Bool {
            if conversationIDs.contains(conversation.id) { return true }
            guard let hash = conversation.participantHash else { return false }
            return participantHashes.contains(hash)
        }

        /// Resolves the deferred lists of the encoded checkpoints against the
        /// store, mirroring `retryScope`. Call inside `context.perform` while
        /// holding the cleanup-sensitive gate: the repair coordinator persists
        /// each batch's checkpoint inside its own hold of that gate, so a
        /// conversation a batch deferred is never missing from this read.
        /// Throws when the existence fetch fails; callers fail closed.
        static func load(
            encodedCheckpoints: [String?],
            in context: NSManagedObjectContext
        ) throws -> Self {
            let entries = encodedCheckpoints.flatMap { Checkpoint.decode($0).deferredConversations }
            guard !entries.isEmpty else { return Self() }
            let request = NSFetchRequest<NSDictionary>(entityName: "Conversation")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            request.predicate = NSPredicate(format: "id IN %@", entries.map(\.id) as NSArray)
            let existingIDs = Set(try context.fetch(request).compactMap { $0["id"] as? UUID })
            var anchors = Self()
            for entry in entries {
                if existingIDs.contains(entry.id) {
                    anchors.conversationIDs.insert(entry.id)
                } else if let hash = entry.participantHash {
                    anchors.participantHashes.insert(hash)
                }
            }
            return anchors
        }
    }
}
