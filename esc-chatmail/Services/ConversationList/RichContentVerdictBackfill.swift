import CoreData
import Foundation

/// Stamps `Message.richContentVerdict` on received rows that hold no verdict under the
/// current epoch: rows persisted before verdicts were stored, and every row after an epoch
/// bump. New and re-synced rows are stamped by `MessagePersister` in the save that writes
/// them, so this only has to walk what was already there. The caller owns the account lease,
/// the save, and the durable cursor (`ConversationLaunchRepairCoordinator`).
///
/// An optimisation, not the source of truth: a row this has not reached reads as unknown,
/// which renders the loading pill exactly as before verdicts existed, and a bubble load
/// re-stamps any row it finds unknown or stale (`MessageBubbleLoader.loadContent`).
///
/// Deliberately its own type rather than a `ChatPreviewRepair.Pass`. That machinery defers
/// conversations with a pending `OutboundSendMutationRecord` and runs under the
/// cleanup-sensitive gate, both of which exist for rewriting `chatPreviewText` (an optimistic
/// row's preview is copied onto its sync echo) and for the deferred list the split and merge
/// passes read. This writes one attribute on received rows found by ID, which no send
/// touches, so it needs neither, and taking the gate would make an optimistic send wait on a
/// mailbox-wide scan.
struct RichContentVerdictBackfill {
    struct Batch: Sendable, Equatable {
        /// The scan cursor after this batch: the lowest message ID examined so far.
        var lastMessageID: String?
        var stampedCount = 0
        /// No received rows remain below the cursor.
        var didDrain = false
    }

    enum BackfillError: Error {
        /// HTML storage refused the reads (account boundary closed or replaced), so no row's
        /// verdict could be established. The batch must not advance the cursor.
        case htmlStorageClosed
    }

    let htmlContentHandler: HTMLContentHandler

    /// Stamps one slice of received rows below `messageID`, newest first: descending by ID,
    /// which for Gmail's IDs is newest mail first, so the chats people open are stamped
    /// before years-old mail.
    ///
    /// Rows already stamped under the current epoch are skipped without a read. A row whose
    /// HTML file exists but cannot be read stays unknown and is passed; a bubble load
    /// re-stamps it when it is next shown.
    func prepareBatch(
        in context: NSManagedObjectContext,
        before messageID: String?,
        limit: Int
    ) async throws -> Batch {
        let limit = max(1, limit)
        // Checked here, on the calling task. Inside `context.perform` there is no current
        // task (the block runs on the context's queue), so `Task.checkCancellation()` there
        // never throws: a batch that has started runs to its end, and the caller's own
        // cancellation check after it discards the result. The batch size, not a per-row
        // check, is what bounds how long the caller's lease is held.
        try Task.checkCancellation()
        return try await context.perform {
            guard let generation = htmlContentHandler.captureAccountGeneration() else {
                throw BackfillError.htmlStorageClosed
            }

            let request = Message.fetchRequest()
            var predicates = [NSPredicate(format: "isFromMe == NO")]
            if let messageID {
                predicates.append(NSPredicate(format: "id < %@", messageID))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: false)]
            request.fetchLimit = limit
            request.returnsObjectsAsFaults = false
            let messages = try context.fetch(request)

            var batch = Batch(lastMessageID: messageID, didDrain: messages.count < limit)
            for message in messages {
                if message.storedRichContentVerdict == .unknown {
                    let verdict = autoreleasepool {
                        RichContentVerdictResolver.verdict(
                            for: message.richContentVerdictInputs,
                            handler: htmlContentHandler,
                            expectedAccountGeneration: generation
                        )
                    }
                    if verdict == .unknown {
                        guard htmlContentHandler.isAccountGenerationCurrent(generation) else {
                            throw BackfillError.htmlStorageClosed
                        }
                    } else {
                        message.storedRichContentVerdict = verdict
                        batch.stampedCount += 1
                    }
                }
                batch.lastMessageID = message.id
            }
            return batch
        }
    }
}
