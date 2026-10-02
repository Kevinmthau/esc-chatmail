import CoreData
import Foundation

extension ChatPreviewRepair {
    /// A conversation whose rows the main scan skipped for a pending send.
    struct DeferredConversation: Codable, Sendable, Equatable {
        var id: UUID
        /// The conversation's participant hash when it was deferred. Locates
        /// its rows if a duplicate merge deletes the conversation before the
        /// retry; see `prepareDeferredRetryBatch`.
        var participantHash: String?

        init(id: UUID, participantHash: String? = nil) {
            self.id = id
            self.participantHash = participantHash
        }

        init(_ conversation: Conversation) {
            self.init(id: conversation.id, participantHash: conversation.participantHash)
        }

        /// The sweep order, shared by the persisted list and `RetryCursor`.
        var sortKey: String { id.uuidString }
    }

    /// One serialized checkpoint keeps the scan cursor and the deferred
    /// conversations together if the process exits between batches.
    ///
    /// Deferred rows are remembered by conversation once the main scan has
    /// passed them, and the scan is marked complete when it drains. Earlier
    /// builds remembered only the first deferred ID and restarted the whole
    /// scan from it whenever a pass drained; a retained failed or
    /// delivery-unknown send can live indefinitely, so those builds re-derived
    /// every later row on every sync completion, holding the cleanup-sensitive
    /// gate that optimistic sends wait on. The build after that remembered
    /// every deferred row by message ID, which grew with the conversation (a
    /// long chat with a retained send deferred thousands of rows) and was
    /// re-encoded into the migration-flag store after every main-scan batch.
    /// Per-conversation entries stay bounded by the conversations that had a
    /// retained send when the scan reached them.
    struct Checkpoint: Codable, Sendable, Equatable {
        var afterMessageID: String?
        /// Legacy: written only by builds that predate deferred lists. A
        /// checkpoint decoded with it set restarts the scan from it once, at
        /// drain, to learn which rows that build skipped; new scans never set it.
        var firstDeferredMessageID: String?
        /// Lower bound for the scan; set only by a legacy restart.
        var resumeAtMessageID: String?
        /// Legacy: the per-row deferred list an earlier build persisted under
        /// `deferredMessageIDs`. Decoded, never written: the next batch maps
        /// it to `deferredConversations` (`legacyDeferredMigration`).
        var legacyDeferredMessageIDs: [String] = []
        /// Sorted by `sortKey`, one entry per conversation: conversations the
        /// main scan skipped rows of for a pending send and has not yet
        /// re-derived.
        var deferredConversations: [DeferredConversation] = []
        var isMainScanComplete = false

        private enum CodingKeys: String, CodingKey {
            case afterMessageID
            case firstDeferredMessageID
            case resumeAtMessageID
            case legacyDeferredMessageIDs = "deferredMessageIDs"
            case deferredConversations
            case isMainScanComplete
        }

        init(
            afterMessageID: String? = nil,
            firstDeferredMessageID: String? = nil,
            resumeAtMessageID: String? = nil,
            legacyDeferredMessageIDs: [String] = [],
            deferredConversations: [DeferredConversation] = [],
            isMainScanComplete: Bool = false
        ) {
            self.afterMessageID = afterMessageID
            self.firstDeferredMessageID = firstDeferredMessageID
            self.resumeAtMessageID = resumeAtMessageID
            self.legacyDeferredMessageIDs = legacyDeferredMessageIDs
            self.deferredConversations = Self.normalized(deferredConversations)
            self.isMainScanComplete = isMainScanComplete
        }

        /// Tolerates every earlier encoding: every key is optional, so a
        /// checkpoint from before deferred lists decodes with an empty list
        /// and an incomplete main scan, and one with a per-row list keeps it
        /// for migration, instead of failing and restarting the pass from
        /// scratch.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            afterMessageID = try container.decodeIfPresent(String.self, forKey: .afterMessageID)
            firstDeferredMessageID = try container.decodeIfPresent(String.self, forKey: .firstDeferredMessageID)
            resumeAtMessageID = try container.decodeIfPresent(String.self, forKey: .resumeAtMessageID)
            legacyDeferredMessageIDs = try container.decodeIfPresent(
                [String].self,
                forKey: .legacyDeferredMessageIDs
            ) ?? []
            deferredConversations = Self.normalized(
                try container.decodeIfPresent([DeferredConversation].self, forKey: .deferredConversations) ?? []
            )
            isMainScanComplete = try container.decodeIfPresent(Bool.self, forKey: .isMainScanComplete) ?? false
        }

        /// Omits empty lists so the steady-state checkpoint stays a few keys.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(afterMessageID, forKey: .afterMessageID)
            try container.encodeIfPresent(firstDeferredMessageID, forKey: .firstDeferredMessageID)
            try container.encodeIfPresent(resumeAtMessageID, forKey: .resumeAtMessageID)
            if !legacyDeferredMessageIDs.isEmpty {
                try container.encode(legacyDeferredMessageIDs, forKey: .legacyDeferredMessageIDs)
            }
            if !deferredConversations.isEmpty {
                try container.encode(deferredConversations, forKey: .deferredConversations)
            }
            try container.encode(isMainScanComplete, forKey: .isMainScanComplete)
        }

        static func decode(_ value: String?) -> Self {
            value.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        }

        var encoded: String? {
            let encoder = JSONEncoder()
            // Stable bytes for equal checkpoints.
            encoder.outputFormatting = .sortedKeys
            return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }

        /// The pass may latch its completion flag: the scan drained and every
        /// deferred conversation has since been re-derived (or no longer exists).
        var isComplete: Bool {
            isMainScanComplete && deferredConversations.isEmpty && legacyDeferredMessageIDs.isEmpty
        }

        /// The checkpoint to persist after `batch` saved successfully.
        func advanced(by batch: Batch) -> Self {
            var next = self
            switch batch.phase {
            case .mainScan:
                next.afterMessageID = batch.lastMessageID
                next.deferredConversations = Self.normalized(deferredConversations + batch.deferredConversations)
                guard batch.didDrain else { return next }
                if let legacyBoundary = firstDeferredMessageID {
                    // A pre-upgrade scan skipped rows from this ID on without
                    // recording which. Rescan that range once; this scan
                    // records what it skips, so the restart cannot repeat.
                    next = Self(
                        resumeAtMessageID: legacyBoundary,
                        legacyDeferredMessageIDs: next.legacyDeferredMessageIDs,
                        deferredConversations: next.deferredConversations
                    )
                } else {
                    next.afterMessageID = nil
                    next.resumeAtMessageID = nil
                    next.isMainScanComplete = true
                }
            case .deferredRetry:
                let retried = Set(batch.retriedConversationIDs)
                next.deferredConversations = deferredConversations.filter { !retried.contains($0.id) }
            case .legacyDeferredMigration:
                next.legacyDeferredMessageIDs = []
                next.deferredConversations = Self.normalized(deferredConversations + batch.deferredConversations)
            }
            return next
        }

        /// One entry per conversation in `sortKey` order. The first entry's
        /// hash wins unless it has none, so a re-deferral cannot erase it.
        private static func normalized(_ entries: [DeferredConversation]) -> [DeferredConversation] {
            var byID: [UUID: DeferredConversation] = [:]
            for entry in entries {
                if let existing = byID[entry.id], existing.participantHash != nil { continue }
                byID[entry.id] = entry
            }
            return byID.values.sorted { $0.sortKey < $1.sortKey }
        }
    }
}
